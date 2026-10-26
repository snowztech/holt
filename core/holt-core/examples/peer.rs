//! A stand-in for a paired Mac, for testing other clients like the iPhone app.
//!
//! `cargo run --release --example peer` prints its id and a pairing code, then logs
//! every clip it receives and how long it took to arrive. After pairing it also sends
//! one clip back, to time the other direction.

use std::collections::HashSet;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use holt_core::{Node, Store};

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn main() {
    let store = Store::open(":memory:".into()).expect("store");
    let node = Node::start(store.clone(), "Test Mac".into()).expect("node");
    println!("id {}", node.device_id());
    let code = node.start_pairing();
    println!("code {code}");
    // Paste this into the iPhone spike's Pair field.
    println!("pair: {} {code}", node.device_id());

    let mut seen = HashSet::new();
    let mut paired = false;
    loop {
        if !paired {
            if let Some(device) = node.devices().unwrap_or_default().first() {
                paired = true;
                println!("paired with {}", device.name);
                store
                    .add(format!("from test mac {}", now_ms()), None)
                    .expect("add");
            }
        }
        for clip in store.search(String::new(), 50).unwrap_or_default() {
            if clip.device.is_some() && seen.insert(clip.id) {
                // created_at is when the other device copied it, on the same clock in a simulator.
                println!(
                    "received {:?} after {} ms",
                    clip.text,
                    now_ms() - clip.created_at
                );
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}
