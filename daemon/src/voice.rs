use std::io::{Read, Write};

use anyhow::{Context, anyhow, bail};
use flate2::{Compression, read::GzDecoder, write::GzEncoder};
use futures_util::SinkExt;
use serde_json::json;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{Message, client::IntoClientRequest},
};
use uuid::Uuid;

use crate::config::VoiceInputConfig;

const MESSAGE_TYPE_FULL_CLIENT_REQUEST: u8 = 0b0001;
const MESSAGE_TYPE_AUDIO_ONLY_REQUEST: u8 = 0b0010;
const MESSAGE_TYPE_FULL_SERVER_RESPONSE: u8 = 0b1001;
const MESSAGE_TYPE_ERROR_RESPONSE: u8 = 0b1111;
const MESSAGE_FLAG_NONE: u8 = 0b0000;
const MESSAGE_FLAG_SEQUENCE: u8 = 0b0001;
const MESSAGE_FLAG_FINAL_PACKET: u8 = 0b0010;
const MESSAGE_FLAG_FINAL_RESPONSE: u8 = 0b0011;
const SERIALIZATION_NONE: u8 = 0b0000;
const SERIALIZATION_JSON: u8 = 0b0001;
const COMPRESSION_NONE: u8 = 0b0000;
const COMPRESSION_GZIP: u8 = 0b0001;

pub struct ProviderMessage {
    pub transcript: Option<String>,
    pub is_final: bool,
    pub error: Option<String>,
}

pub async fn connect_provider(
    config: &VoiceInputConfig,
) -> anyhow::Result<(
    WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>,
    tokio_tungstenite::tungstenite::handshake::client::Response,
)> {
    let mut request = config
        .websocket_url
        .clone()
        .into_client_request()
        .context("invalid voice input websocket URL")?;
    let request_id = Uuid::new_v4().to_string();
    let headers = request.headers_mut();
    headers.insert("X-Api-App-Key", config.app_id.parse()?);
    headers.insert("X-Api-Access-Key", config.access_token.parse()?);
    headers.insert("X-Api-Resource-Id", config.resource_id.parse()?);
    headers.insert("X-Api-Connect-Id", request_id.parse()?);
    headers.insert("X-Api-Request-Id", request_id.parse()?);
    headers.insert("X-Api-Sequence", "-1".parse()?);

    let (mut socket, response) = connect_async(request).await?;
    socket
        .send(Message::Binary(build_full_client_request()?.into()))
        .await?;

    Ok((socket, response))
}

pub fn build_audio_request(chunk: &[u8], final_packet: bool) -> anyhow::Result<Vec<u8>> {
    build_client_message(
        MESSAGE_TYPE_AUDIO_ONLY_REQUEST,
        if final_packet {
            MESSAGE_FLAG_FINAL_PACKET
        } else {
            MESSAGE_FLAG_NONE
        },
        SERIALIZATION_NONE,
        COMPRESSION_GZIP,
        chunk,
    )
}

pub fn parse_provider_message(frame: &[u8]) -> anyhow::Result<ProviderMessage> {
    if frame.len() < 8 {
        bail!("provider response frame too short");
    }

    let message_type = frame[1] >> 4;
    let flags = frame[1] & 0x0f;
    let serialization = frame[2] >> 4;
    let compression = frame[2] & 0x0f;
    let mut cursor = 4;

    if matches!(flags, MESSAGE_FLAG_SEQUENCE | MESSAGE_FLAG_FINAL_RESPONSE) {
        if frame.len() < cursor + 4 {
            bail!("provider response frame missing sequence");
        }
        cursor += 4;
    }

    if frame.len() < cursor + 4 {
        bail!("provider response frame missing payload size");
    }

    let payload_size = u32::from_be_bytes(
        frame[cursor..cursor + 4]
            .try_into()
            .map_err(|_| anyhow!("invalid provider payload size"))?,
    ) as usize;
    cursor += 4;

    let payload = frame
        .get(cursor..cursor + payload_size)
        .context("provider response payload truncated")?;
    let payload = if compression == COMPRESSION_GZIP {
        gunzip(payload)?
    } else if compression == COMPRESSION_NONE {
        payload.to_vec()
    } else {
        bail!("unsupported provider compression format");
    };

    match message_type {
        MESSAGE_TYPE_FULL_SERVER_RESPONSE => {
            let transcript = if serialization == SERIALIZATION_JSON {
                serde_json::from_slice::<serde_json::Value>(&payload)?
                    .get("result")
                    .and_then(|value| value.get("text"))
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_string)
            } else {
                None
            };

            Ok(ProviderMessage {
                transcript,
                is_final: flags == MESSAGE_FLAG_FINAL_RESPONSE,
                error: None,
            })
        }
        MESSAGE_TYPE_ERROR_RESPONSE => Ok(ProviderMessage {
            transcript: None,
            is_final: true,
            error: Some(parse_error_payload(serialization, &payload)?),
        }),
        _ => Ok(ProviderMessage {
            transcript: None,
            is_final: false,
            error: None,
        }),
    }
}

fn build_full_client_request() -> anyhow::Result<Vec<u8>> {
    build_client_message(
        MESSAGE_TYPE_FULL_CLIENT_REQUEST,
        MESSAGE_FLAG_NONE,
        SERIALIZATION_JSON,
        COMPRESSION_GZIP,
        serde_json::to_string(&json!({
            "user": {
                "uid": "agent-dock",
            },
            "audio": {
                "format": "pcm",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
                "language": "zh-CN",
            },
            "request": {
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
            }
        }))?
        .as_bytes(),
    )
}

fn build_client_message(
    message_type: u8,
    flags: u8,
    serialization: u8,
    compression: u8,
    payload: &[u8],
) -> anyhow::Result<Vec<u8>> {
    let payload = if compression == COMPRESSION_GZIP {
        gzip(payload)?
    } else {
        payload.to_vec()
    };
    let mut frame = vec![
        0x11,
        (message_type << 4) | flags,
        (serialization << 4) | compression,
        0x00,
    ];
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

fn parse_error_payload(serialization: u8, payload: &[u8]) -> anyhow::Result<String> {
    if serialization == SERIALIZATION_JSON {
        let value = serde_json::from_slice::<serde_json::Value>(payload)?;
        if let Some(message) = value
            .get("message")
            .and_then(serde_json::Value::as_str)
            .or_else(|| value.get("error").and_then(serde_json::Value::as_str))
        {
            return Ok(message.to_string());
        }

        return Ok(value.to_string());
    }

    Ok(String::from_utf8_lossy(payload).into_owned())
}

fn gzip(payload: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(payload)?;
    Ok(encoder.finish()?)
}

fn gunzip(payload: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut decoder = GzDecoder::new(payload);
    let mut output = Vec::new();
    decoder.read_to_end(&mut output)?;
    Ok(output)
}
