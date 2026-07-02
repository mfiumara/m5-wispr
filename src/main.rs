use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{anyhow, Result};
use esp32_nimble::{
    enums::{AuthReq, PowerLevel, PowerType, SecurityIOCap},
    hid::*,
    utilities::mutex::Mutex,
    uuid128, BLEAdvertisementData, BLECharacteristic, BLEDevice, BLEHIDDevice, NimbleProperties,
};
use esp_idf_svc::hal::delay::FreeRtos;
use m5unified::{colors, M5Unified, M5UnifiedConfig, Rect};

const DEVICE_NAME: &str = "m5sticks3";

const SAMPLE_RATE_HZ: u32 = 16_000;
const AUDIO_CHANNELS: u8 = 1;
const AUDIO_BITS_PER_SAMPLE: u8 = 16;
const AUDIO_SAMPLES_PER_PACKET: usize = 80;
const AUDIO_PACKET_HEADER_BYTES: usize = 8;
const AUDIO_PACKET_BYTES: usize = AUDIO_PACKET_HEADER_BYTES + AUDIO_SAMPLES_PER_PACKET * 2;

const AUDIO_FLAG_START: u8 = 0x01;
const AUDIO_FLAG_STOP: u8 = 0x02;

const KEYBOARD_REPORT_ID: u8 = 0x01;

// macOS does not expose the Apple Fn/Globe key as a normal external BLE HID
// key. Hold a modifier-only key instead so macOS has no repeatable key to spam.
const HID_KEY_NONE: u8 = 0x00;
const HID_MOD_RIGHT_OPTION: u8 = 0x40;
const WISPR_HOTKEY_USAGE: u8 = HID_KEY_NONE;
const WISPR_HOTKEY_MODIFIERS: u8 = HID_MOD_RIGHT_OPTION;

const DISPLAY_BRIGHTNESS: u8 = 96;
const BATTERY_DISPLAY_MS: u64 = 2_500;
const BATTERY_REFRESH_MS: u64 = 1_000;
const IDLE_LOOP_MS: u32 = 20;

// The recording animation is a pre-rendered gif: portrait full-screen frames
// cropped around Jigglypuff's face, stored as swap565 (big-endian RGB565), the
// layout LovyanGFX pushImage expects while swapBytes stays disabled.
// Regenerate with tools/gif2rgb565.py (--focus-x 0.43 --zoom 0.79).
const RECORDING_GIF_WIDTH: i32 = 135;
const RECORDING_GIF_HEIGHT: i32 = 240;
const RECORDING_GIF_FRAME_COUNT: usize = 16;
const RECORDING_GIF_FRAME_MS: u64 = 130;
const RECORDING_GIF_FRAME_PIXELS: usize =
    (RECORDING_GIF_WIDTH * RECORDING_GIF_HEIGHT) as usize;
const RECORDING_GIF_BYTES: usize = RECORDING_GIF_FRAME_COUNT * RECORDING_GIF_FRAME_PIXELS * 2;

#[repr(align(2))]
struct AlignedPixelBytes<const N: usize>([u8; N]);

static RECORDING_GIF: AlignedPixelBytes<RECORDING_GIF_BYTES> =
    AlignedPixelBytes(*include_bytes!("../assets/recording_gif_135x240.rgb565"));

fn recording_gif_frame(index: usize) -> &'static [u16] {
    let start = index * RECORDING_GIF_FRAME_PIXELS * 2;
    let bytes = &RECORDING_GIF.0[start..start + RECORDING_GIF_FRAME_PIXELS * 2];
    // Safety: the backing static is align(2) and every frame offset is even, so
    // the bytes reinterpret cleanly as native u16 pixels.
    unsafe {
        core::slice::from_raw_parts(bytes.as_ptr().cast::<u16>(), RECORDING_GIF_FRAME_PIXELS)
    }
}

struct RecordingGifPlayer {
    started: Instant,
    pushed_frame: Option<usize>,
}

impl RecordingGifPlayer {
    fn new(now: Instant) -> Self {
        Self {
            started: now,
            pushed_frame: None,
        }
    }

    fn reset(&mut self, now: Instant) {
        self.started = now;
        self.pushed_frame = None;
    }

    fn current_frame(&self, now: Instant) -> usize {
        let elapsed_ms = now.duration_since(self.started).as_millis() as u64;
        (elapsed_ms / RECORDING_GIF_FRAME_MS) as usize % RECORDING_GIF_FRAME_COUNT
    }

    fn frame_to_push(&self, now: Instant) -> Option<usize> {
        let frame = self.current_frame(now);
        (self.pushed_frame != Some(frame)).then_some(frame)
    }

    fn mark_pushed(&mut self, frame: usize) {
        self.pushed_frame = Some(frame);
    }
}

const HID_REPORT_DESCRIPTOR: &[u8] = hid!(
    (USAGE_PAGE, 0x01),
    (USAGE, 0x06),
    (COLLECTION, 0x01),
    (REPORT_ID, KEYBOARD_REPORT_ID),
    (USAGE_PAGE, 0x07),
    (USAGE_MINIMUM, 0xE0),
    (USAGE_MAXIMUM, 0xE7),
    (LOGICAL_MINIMUM, 0x00),
    (LOGICAL_MAXIMUM, 0x01),
    (REPORT_SIZE, 0x01),
    (REPORT_COUNT, 0x08),
    (HIDINPUT, 0x02),
    (REPORT_COUNT, 0x01),
    (REPORT_SIZE, 0x08),
    (HIDINPUT, 0x01),
    (REPORT_COUNT, 0x05),
    (REPORT_SIZE, 0x01),
    (USAGE_PAGE, 0x08),
    (USAGE_MINIMUM, 0x01),
    (USAGE_MAXIMUM, 0x05),
    (HIDOUTPUT, 0x02),
    (REPORT_COUNT, 0x01),
    (REPORT_SIZE, 0x03),
    (HIDOUTPUT, 0x01),
    (REPORT_COUNT, 0x06),
    (REPORT_SIZE, 0x08),
    (LOGICAL_MINIMUM, 0x00),
    (LOGICAL_MAXIMUM, 0x73),
    (USAGE_PAGE, 0x07),
    (USAGE_MINIMUM, 0x00),
    (USAGE_MAXIMUM, 0x73),
    (HIDINPUT, 0x00),
    (END_COLLECTION),
);

struct BlePeripherals {
    hid: BLEHIDDevice,
    keyboard_input: Arc<Mutex<BLECharacteristic>>,
    audio_stream: Arc<Mutex<BLECharacteristic>>,
    sequence: u32,
    key_down: bool,
}

impl BlePeripherals {
    fn new() -> Result<Self> {
        let device = BLEDevice::take();
        BLEDevice::set_device_name(DEVICE_NAME)?;
        device
            .security()
            .set_auth(AuthReq::Bond | AuthReq::Sc)
            .set_io_cap(SecurityIOCap::NoInputNoOutput)
            .resolve_rpa();

        let _ = device.set_power(PowerType::Advertising, PowerLevel::P3);
        let _ = device.set_power(PowerType::Default, PowerLevel::P3);

        let advertising = device.get_advertising();
        let server = device.get_server();

        server.on_connect(|server, desc| {
            log::info!("BLE client connected: {:?}", desc);
            let _ = server.update_conn_params(desc.conn_handle(), 6, 12, 0, 60);
        });

        server.on_disconnect(|desc, reason| {
            log::info!("BLE client disconnected: {:?}, reason={reason:?}", desc);
            let _ = BLEDevice::take().get_advertising().lock().start();
        });

        let mut hid = BLEHIDDevice::new(server);
        let keyboard_input = hid.input_report(KEYBOARD_REPORT_ID);
        let _keyboard_output = hid.output_report(KEYBOARD_REPORT_ID);

        hid.manufacturer("M5Stack");
        hid.pnp(0x02, 0x303a, 0x4001, 0x0100);
        hid.hid_info(0x00, 0x01);
        hid.report_map(HID_REPORT_DESCRIPTOR);
        hid.set_battery_level(100);

        let audio_service_uuid = uuid128!("b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100");
        let audio_service = server.create_service(audio_service_uuid);
        let audio_stream = audio_service.lock().create_characteristic(
            uuid128!("b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100"),
            NimbleProperties::READ | NimbleProperties::NOTIFY,
        );
        audio_stream.lock().set_value(&[]);

        let audio_config = audio_service.lock().create_characteristic(
            uuid128!("b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100"),
            NimbleProperties::READ,
        );
        audio_config.lock().set_value(&audio_config_payload());

        advertising.lock().scan_response(true).set_data(
            BLEAdvertisementData::new()
                .name(DEVICE_NAME)
                .appearance(0x03C1)
                .add_service_uuid(hid.hid_service().lock().uuid())
                .add_service_uuid(audio_service_uuid),
        )?;
        advertising.lock().start()?;

        server.ble_gatts_show_local();

        Ok(Self {
            hid,
            keyboard_input,
            audio_stream,
            sequence: 0,
            key_down: false,
        })
    }

    fn set_battery_level(&mut self, level: Option<u8>) {
        self.hid.set_battery_level(level.unwrap_or(0));
    }

    fn set_hotkey(&mut self, pressed: bool) {
        if self.key_down == pressed {
            return;
        }

        let report = if pressed {
            keyboard_report(WISPR_HOTKEY_MODIFIERS, WISPR_HOTKEY_USAGE)
        } else {
            keyboard_report(0, 0)
        };

        self.keyboard_input.lock().set_value(&report).notify();
        self.key_down = pressed;
        FreeRtos::delay_ms(7);
    }

    fn send_audio_packet(&mut self, samples: &[i16], flags: u8) {
        let sample_count = samples.len().min(AUDIO_SAMPLES_PER_PACKET);
        let mut packet = [0_u8; AUDIO_PACKET_BYTES];
        packet[0..4].copy_from_slice(&self.sequence.to_le_bytes());
        packet[4] = flags;
        packet[5] = AUDIO_CHANNELS;
        packet[6..8].copy_from_slice(&(sample_count as u16).to_le_bytes());

        for (index, sample) in samples.iter().take(sample_count).enumerate() {
            let offset = AUDIO_PACKET_HEADER_BYTES + index * 2;
            packet[offset..offset + 2].copy_from_slice(&sample.to_le_bytes());
        }

        let packet_len = AUDIO_PACKET_HEADER_BYTES + sample_count * 2;
        self.audio_stream
            .lock()
            .set_value(&packet[..packet_len])
            .notify();
        self.sequence = self.sequence.wrapping_add(1);
    }

    fn send_stop_marker(&mut self) {
        self.send_audio_packet(&[], AUDIO_FLAG_STOP);
    }
}

fn main() -> Result<()> {
    esp_idf_sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();

    let mut m5 = M5Unified::begin_with_config(&m5_config())?;
    m5.display.set_rotation(0);
    m5.power.set_led(0);

    let mut mic_cfg = m5.mic.config();
    mic_cfg.sample_rate = SAMPLE_RATE_HZ;
    mic_cfg.stereo = false;
    mic_cfg.noise_filter_level = mic_cfg.noise_filter_level.saturating_add(8);
    m5.mic.set_config(mic_cfg)?;

    sleep_display(&mut m5);

    let mut ble = BlePeripherals::new()?;
    let mut samples = [0_i16; AUDIO_SAMPLES_PER_PACKET];
    let mut recording = false;
    let mut pending_start_flag = false;
    let mut battery_visible_until: Option<Instant> = None;
    let mut last_battery_refresh = Instant::now() - Duration::from_secs(60);
    let mut gif_player = RecordingGifPlayer::new(Instant::now());

    loop {
        m5.update();
        let pressed = m5.buttons.a().is_pressed();

        if pressed && !recording {
            recording = true;
            pending_start_flag = true;
            battery_visible_until = None;
            gif_player.reset(Instant::now());
            ble.set_hotkey(true);
            wake_display(&mut m5);
            render_recording_frame(&mut m5, 0)?;
            gif_player.mark_pushed(0);

            if !start_microphone(&mut m5) {
                render_status(&mut m5, "MIC UNAVAILABLE")?;
            }
        }

        if !pressed && recording {
            recording = false;
            pending_start_flag = false;
            m5.mic.end();
            ble.send_stop_marker();
            ble.set_hotkey(false);
            render_battery(&mut m5, &mut ble)?;
            battery_visible_until =
                Some(Instant::now() + Duration::from_millis(BATTERY_DISPLAY_MS));
            last_battery_refresh = Instant::now();
        }

        if recording {
            let recorded = m5.mic.record_i16_at(&mut samples, SAMPLE_RATE_HZ);
            if recorded {
                let flags = if pending_start_flag {
                    pending_start_flag = false;
                    AUDIO_FLAG_START
                } else {
                    0
                };
                ble.send_audio_packet(&samples, flags);

                if let Some(frame) = gif_player.frame_to_push(Instant::now()) {
                    render_recording_frame(&mut m5, frame)?;
                    gif_player.mark_pushed(frame);
                }
            } else {
                FreeRtos::delay_ms(2);
            }
            continue;
        }

        if let Some(until) = battery_visible_until {
            let now = Instant::now();
            if now >= until {
                sleep_display(&mut m5);
                battery_visible_until = None;
            } else if now.duration_since(last_battery_refresh)
                >= Duration::from_millis(BATTERY_REFRESH_MS)
            {
                render_battery(&mut m5, &mut ble)?;
                last_battery_refresh = now;
            }
        }

        // Keep the idle path light; BLE advertising and connections run in host tasks.
        FreeRtos::delay_ms(IDLE_LOOP_MS);
    }
}

fn m5_config() -> M5UnifiedConfig {
    let mut config = M5UnifiedConfig::default();
    config.clear_display = true;
    config.output_power = false;
    config.internal_imu = false;
    config.internal_rtc = false;
    config.internal_spk = false;
    config.internal_mic = true;
    config.led_brightness = 0;
    config
}

fn audio_config_payload() -> [u8; 16] {
    let mut payload = [0_u8; 16];
    payload[0..4].copy_from_slice(b"M5W1");
    payload[4..8].copy_from_slice(&SAMPLE_RATE_HZ.to_le_bytes());
    payload[8] = AUDIO_BITS_PER_SAMPLE;
    payload[9] = AUDIO_CHANNELS;
    payload[10..12].copy_from_slice(&(AUDIO_SAMPLES_PER_PACKET as u16).to_le_bytes());
    payload[12..16].copy_from_slice(&(AUDIO_PACKET_HEADER_BYTES as u32).to_le_bytes());
    payload
}

fn keyboard_report(modifiers: u8, key: u8) -> [u8; 8] {
    let mut report = [0_u8; 8];
    report[0] = modifiers;
    report[2] = key;
    report
}

fn start_microphone(m5: &mut M5Unified) -> bool {
    m5.mic.is_enabled() || m5.mic.begin()
}

fn wake_display(m5: &mut M5Unified) {
    m5.display.power_save(false);
    m5.display.wakeup();
    m5.display.set_brightness(DISPLAY_BRIGHTNESS);
    m5.display.fill_screen(colors::BLACK);
}

fn sleep_display(m5: &mut M5Unified) {
    m5.display.fill_screen(colors::BLACK);
    m5.display.set_brightness(0);
    m5.display.sleep();
    m5.display.power_save(true);
}

fn render_recording_frame(m5: &mut M5Unified, frame: usize) -> Result<()> {
    let rect = Rect {
        x: 0,
        y: 0,
        w: RECORDING_GIF_WIDTH,
        h: RECORDING_GIF_HEIGHT,
    };
    m5.display
        .push_image_rgb565(rect, recording_gif_frame(frame))
        .map_err(|error| anyhow!("push recording gif frame {frame}: {error:?}"))?;
    Ok(())
}

fn render_battery(m5: &mut M5Unified, ble: &mut BlePeripherals) -> Result<()> {
    wake_display(m5);
    let level = m5.power.battery_level();
    ble.set_battery_level(level);

    let width = m5.display.width();
    let height = m5.display.height();
    let pct = level.unwrap_or(0).min(100);
    let charging = m5.power.is_charging();

    let body_w = (width - 48).max(72);
    let body_h = 34;
    let body_x = (width - body_w) / 2 - 6;
    let body_y = height / 2 - 18;
    let fill_w = ((body_w - 8) * pct as i32) / 100;
    let fill_color = if pct <= 20 {
        colors::RED
    } else if pct <= 50 {
        colors::ORANGE
    } else {
        colors::GREEN
    };

    m5.display.fill_screen(colors::BLACK);
    m5.display
        .draw_round_rect(body_x, body_y, body_w, body_h, 6, colors::WHITE);
    m5.display.fill_round_rect(
        body_x + body_w,
        body_y + body_h / 4,
        8,
        body_h / 2,
        3,
        colors::WHITE,
    );
    if fill_w > 0 {
        m5.display
            .fill_rect(body_x + 4, body_y + 4, fill_w, body_h - 8, fill_color);
    }

    m5.display.set_text_color(colors::WHITE, colors::BLACK);
    m5.display.set_text_size(3);
    let pct_text = if level.is_some() {
        format!("{pct}%")
    } else {
        "--%".to_owned()
    };
    m5.display.set_cursor(width / 2 - 36, body_y - 38);
    m5.display.println(&pct_text)?;

    m5.display.set_text_size(1);
    m5.display.set_cursor(8, height - 18);
    let voltage = m5
        .power
        .battery_voltage_mv()
        .map(|mv| format!("{:.2}V", mv as f32 / 1000.0))
        .unwrap_or_else(|| "battery voltage n/a".to_owned());
    if charging {
        m5.display.println(&format!("{voltage} charging"))?;
    } else {
        m5.display.println(&voltage)?;
    }

    Ok(())
}

fn render_status(m5: &mut M5Unified, message: &str) -> Result<()> {
    let width = m5.display.width();
    let height = m5.display.height();
    m5.display.fill_screen(colors::BLACK);
    m5.display.set_text_color(colors::RED, colors::BLACK);
    m5.display.set_text_size(2);
    m5.display.set_cursor(8, height / 2 - 12);
    if message.is_empty() {
        return Err(anyhow!("empty status message"));
    }
    let max_chars = ((width - 16) / 12).max(1) as usize;
    m5.display
        .println(&message[..message.len().min(max_chars)])?;
    Ok(())
}
