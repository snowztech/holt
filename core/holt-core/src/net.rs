//! Pairing and sync between devices, over iroh.
//!
//! Pairing: one device shows a 6-digit code and advertises itself on the local
//! network. The other picks it from the nearby list and types the code. Both run
//! SPAKE2 with the code, so a wrong guess fails and an eavesdropper learns
//! nothing to brute-force offline. Each side then saves the other's key.
//!
//! Sync: paired devices hold one connection open. Each side says what it already
//! has (the highest seq seen per origin), then sends everything the other lacks
//! and keeps sending as clips change.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh::address_lookup::{MemoryLookup, UserData};
use iroh::endpoint::{presets, Connection, RecvStream, SendStream};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointId, RelayMode, SecretKey};
use iroh_mdns_address_lookup::{DiscoveryEvent, MdnsAddressLookup};
use n0_future::StreamExt;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use spake2::{Ed25519Group, Identity, Password, Spake2};
use tokio::task::JoinHandle;

use crate::{HoltError, Result, Row, Store};

const SYNC_ALPN: &[u8] = b"holt/sync/1";
const PAIR_ALPN: &[u8] = b"holt/pair/1";
/// Prefix of the mDNS user data a device advertises while it's ready to pair.
const PAIR_PREFIX: &str = "holt-pair:";
const MAX_FRAME_BYTES: usize = 16 << 20;
/// Rows are batched up to roughly this much text per message.
const BATCH_BYTES: usize = 2 << 20;
const NOT_PAIRING: &str = "Couldn't reach the other device. Make sure it's still showing its code.";
/// Wrong codes allowed before the pairing code stops working.
const MAX_PAIR_FAILURES: u32 = 5;

type BoxError = Box<dyn std::error::Error + Send + Sync>;
type NetResult<T> = std::result::Result<T, BoxError>;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub online: bool,
}

#[derive(uniffi::Object)]
pub struct Node {
    inner: Arc<Inner>,
    _router: Router,
    // Dropped last, after the router, so its tasks shut down cleanly.
    rt: tokio::runtime::Runtime,
}

struct Inner {
    store: Arc<Store>,
    endpoint: Endpoint,
    name: String,
    /// Holds peer addresses in tests, where there's no mDNS or relay.
    #[cfg_attr(not(test), allow(dead_code))]
    memory: MemoryLookup,
    pairing: Mutex<Option<Pairing>>,
    /// Devices on the local network that are ready to pair, by id.
    nearby: Mutex<HashMap<EndpointId, String>>,
    /// Open sync sessions per peer.
    online: Mutex<HashMap<EndpointId, usize>>,
    dialers: Mutex<HashMap<EndpointId, JoinHandle<()>>>,
}

struct Pairing {
    code: String,
    failures: u32,
}

#[uniffi::export]
impl Node {
    /// Starts networking: listens for paired devices, connects to them, and
    /// watches the local network for devices that want to pair.
    #[uniffi::constructor]
    pub fn start(store: Arc<Store>, device_name: String) -> Result<Arc<Self>> {
        Self::start_with(store, device_name, false)
    }

    pub fn device_id(&self) -> String {
        self.inner.endpoint.id().to_string()
    }

    /// Makes this device pairable and returns the code to show the user.
    pub fn start_pairing(&self) -> String {
        let code = format!("{:06}", rand::random_range(0..1_000_000u32));
        *self.inner.pairing.lock().unwrap() = Some(Pairing {
            code: code.clone(),
            failures: 0,
        });
        let mut advert = format!("{PAIR_PREFIX}{}", self.inner.name);
        while advert.len() > UserData::MAX_LENGTH {
            advert.pop();
        }
        self.inner
            .endpoint
            .set_user_data_for_address_lookup(advert.parse().ok());
        code
    }

    pub fn stop_pairing(&self) {
        self.inner.stop_pairing();
    }

    /// Devices on this network that are showing a pairing code right now.
    pub fn nearby(&self) -> Vec<Device> {
        let paired = self.paired_ids();
        let mut devices: Vec<Device> = self
            .inner
            .nearby
            .lock()
            .unwrap()
            .iter()
            .filter(|(id, _)| !paired.contains(&id.to_string()))
            .map(|(id, name)| Device {
                id: id.to_string(),
                name: name.clone(),
                online: true,
            })
            .collect();
        devices.sort_by(|a, b| a.name.cmp(&b.name));
        devices
    }

    /// Pairs with a nearby device using the code it shows. Blocks until done,
    /// so call it off the main thread.
    pub fn pair(&self, device_id: String, code: String) -> Result<Device> {
        let id: EndpointId = device_id
            .parse()
            .map_err(|_| HoltError::Pairing("That device isn't available.".into()))?;
        let code: String = code.chars().filter(|c| !c.is_whitespace()).collect();
        let inner = self.inner.clone();
        self.rt.block_on(async move {
            tokio::time::timeout(Duration::from_secs(20), join_pairing(inner, id, code))
                .await
                .unwrap_or_else(|_| Err(HoltError::Pairing(NOT_PAIRING.into())))
        })
    }

    /// Paired devices, with whether each is connected right now.
    pub fn devices(&self) -> Result<Vec<Device>> {
        let online = self.inner.online.lock().unwrap().clone();
        Ok(self
            .inner
            .store
            .peers()?
            .into_iter()
            .map(|(id, name)| {
                let online = id
                    .parse::<EndpointId>()
                    .ok()
                    .and_then(|id| online.get(&id).copied())
                    .unwrap_or(0)
                    > 0;
                Device { id, name, online }
            })
            .collect())
    }

    /// Unpairs a device here. It stops syncing with this one right away.
    pub fn remove_device(&self, device_id: String) -> Result<()> {
        self.inner.store.remove_peer(&device_id)?;
        if let Ok(id) = device_id.parse::<EndpointId>() {
            if let Some(task) = self.inner.dialers.lock().unwrap().remove(&id) {
                task.abort();
            }
        }
        Ok(())
    }
}

impl Node {
    fn start_with(store: Arc<Store>, name: String, local_only: bool) -> Result<Arc<Self>> {
        let net = |e: BoxError| HoltError::Net(e.to_string());
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| HoltError::Net(e.to_string()))?;
        store.set_device_name(&name);
        let (inner, router) = rt.block_on(async {
            let secret = SecretKey::from_bytes(&store.secret_key());
            let builder = if local_only {
                Endpoint::builder(presets::Minimal)
                    .relay_mode(RelayMode::Disabled)
                    .bind_addr("127.0.0.1:0")
                    .map_err(|e| net(e.into()))?
            } else {
                Endpoint::builder(presets::N0)
            };
            let endpoint = builder
                .secret_key(secret)
                .bind()
                .await
                .map_err(|e| net(e.into()))?;
            let memory = MemoryLookup::new();
            let lookup = endpoint.address_lookup().map_err(|e| net(e.into()))?;
            lookup.add(memory.clone());

            let inner = Arc::new(Inner {
                store,
                endpoint: endpoint.clone(),
                name,
                memory,
                pairing: Mutex::new(None),
                nearby: Mutex::new(HashMap::new()),
                online: Mutex::new(HashMap::new()),
                dialers: Mutex::new(HashMap::new()),
            });
            if !local_only {
                let mdns = MdnsAddressLookup::builder()
                    .build(endpoint.id())
                    .map_err(|e| net(e.into()))?;
                lookup.add(mdns.clone());
                tokio::spawn(watch_nearby(inner.clone(), mdns));
            }
            let router = Router::builder(endpoint)
                .accept(SYNC_ALPN, SyncHandler(inner.clone()))
                .accept(PAIR_ALPN, PairHandler(inner.clone()))
                .spawn();
            for (id, _) in inner.store.peers()? {
                if let Ok(id) = id.parse() {
                    inner.ensure_dialer(id);
                }
            }
            Ok::<_, HoltError>((inner, router))
        })?;
        Ok(Arc::new(Node {
            inner,
            _router: router,
            rt,
        }))
    }

    fn paired_ids(&self) -> Vec<String> {
        self.inner
            .store
            .peers()
            .unwrap_or_default()
            .into_iter()
            .map(|(id, _)| id)
            .collect()
    }
}

impl Inner {
    fn stop_pairing(&self) {
        *self.pairing.lock().unwrap() = None;
        self.endpoint.set_user_data_for_address_lookup(None);
    }

    /// Keeps a connection to `peer` open, reconnecting with backoff. Only the
    /// device with the smaller id dials, so a pair never opens two sessions.
    fn ensure_dialer(self: &Arc<Self>, peer: EndpointId) {
        if self.endpoint.id().as_bytes() >= peer.as_bytes() {
            return;
        }
        let mut dialers = self.dialers.lock().unwrap();
        if dialers.contains_key(&peer) {
            return;
        }
        let inner = self.clone();
        dialers.insert(
            peer,
            tokio::spawn(async move {
                let mut backoff = 1;
                loop {
                    if let Ok(conn) = inner.endpoint.connect(peer, SYNC_ALPN).await {
                        backoff = 1;
                        let _ = sync_session(inner.clone(), conn, true).await;
                    }
                    tokio::time::sleep(Duration::from_secs(backoff)).await;
                    backoff = (backoff * 2).min(30);
                }
            }),
        );
    }

    fn set_online(&self, peer: EndpointId, delta: isize) {
        let mut online = self.online.lock().unwrap();
        let count = online.entry(peer).or_insert(0);
        *count = count.saturating_add_signed(delta);
    }
}

#[derive(Serialize, Deserialize)]
enum SyncMsg {
    Hello {
        name: String,
        cursors: HashMap<String, i64>,
    },
    Rows(Vec<Row>),
}

async fn sync_session(inner: Arc<Inner>, conn: Connection, dialer: bool) -> NetResult<()> {
    let peer = conn.remote_id();
    let peer_id = peer.to_string();
    if !inner.store.is_peer(&peer_id)? {
        conn.close(1u32.into(), b"not paired");
        return Ok(());
    }
    let (mut send, mut recv) = if dialer {
        conn.open_bi().await?
    } else {
        conn.accept_bi().await?
    };
    write_msg(
        &mut send,
        &SyncMsg::Hello {
            name: inner.name.clone(),
            cursors: inner.store.cursors()?,
        },
    )
    .await?;
    let SyncMsg::Hello { name, cursors } = read_msg(&mut recv).await? else {
        return Err("expected hello".into());
    };
    inner.store.add_peer(&peer_id, &name)?;

    // What the peer has, per origin. Updated as we send and as they send.
    let theirs = Mutex::new(cursors);
    inner.set_online(peer, 1);
    let result = tokio::select! {
        r = send_changes(&inner, &mut send, &theirs, &peer_id) => r,
        r = receive_changes(&inner, &mut recv, &theirs) => r,
    };
    inner.set_online(peer, -1);
    result
}

async fn send_changes(
    inner: &Inner,
    send: &mut SendStream,
    theirs: &Mutex<HashMap<String, i64>>,
    peer_id: &str,
) -> NetResult<()> {
    let mut changes = inner.store.subscribe();
    loop {
        changes.borrow_and_update();
        for origin in inner.store.origins()? {
            if origin == peer_id {
                continue;
            }
            loop {
                let after = theirs.lock().unwrap().get(&origin).copied().unwrap_or(0);
                let rows = inner.store.rows_since(&origin, after, 200)?;
                let Some(last) = rows.last().map(|r| r.seq) else {
                    break;
                };
                for batch in batches(rows) {
                    write_msg(send, &SyncMsg::Rows(batch)).await?;
                }
                let mut theirs = theirs.lock().unwrap();
                let seen = theirs.entry(origin.clone()).or_insert(0);
                *seen = (*seen).max(last);
            }
        }
        changes.changed().await?;
    }
}

async fn receive_changes(
    inner: &Inner,
    recv: &mut RecvStream,
    theirs: &Mutex<HashMap<String, i64>>,
) -> NetResult<()> {
    loop {
        if let SyncMsg::Rows(rows) = read_msg(recv).await? {
            {
                // They obviously have what they sent, so don't echo it back.
                let mut theirs = theirs.lock().unwrap();
                for row in &rows {
                    let seen = theirs.entry(row.origin.clone()).or_insert(0);
                    *seen = (*seen).max(row.seq);
                }
            }
            inner.store.apply(rows)?;
        }
    }
}

fn batches(rows: Vec<Row>) -> Vec<Vec<Row>> {
    let mut out: Vec<Vec<Row>> = vec![];
    let mut size = 0;
    for row in rows {
        let len = row.text.as_ref().map_or(0, |t| t.len()) + 200;
        if out.is_empty() || size + len > BATCH_BYTES {
            out.push(vec![]);
            size = 0;
        }
        size += len;
        out.last_mut().unwrap().push(row);
    }
    out
}

#[derive(Serialize, Deserialize)]
enum PairMsg {
    Spake(Vec<u8>),
    Confirm(Vec<u8>),
    Name(String),
    Rejected,
}

fn spake_start(code: &str) -> (Spake2<Ed25519Group>, Vec<u8>) {
    Spake2::<Ed25519Group>::start_symmetric(
        &Password::new(code.as_bytes()),
        &Identity::new(b"holt-pair-1"),
    )
}

/// Proves knowledge of the shared key, bound to both device ids and the role.
fn confirm_tag(key: &[u8], role: &[u8], host: &EndpointId, joiner: &EndpointId) -> Vec<u8> {
    let mut k = [0u8; 32];
    k.copy_from_slice(&key[..32]);
    let mut h = blake3::Hasher::new_keyed(&k);
    h.update(role)
        .update(host.as_bytes())
        .update(joiner.as_bytes());
    h.finalize().as_bytes().to_vec()
}

/// The side that showed the code.
async fn host_pairing(inner: Arc<Inner>, conn: Connection) -> NetResult<()> {
    let Some(code) = inner
        .pairing
        .lock()
        .unwrap()
        .as_ref()
        .map(|p| p.code.clone())
    else {
        conn.close(1u32.into(), b"not pairing");
        return Ok(());
    };
    let (host, joiner) = (inner.endpoint.id(), conn.remote_id());
    let (mut send, mut recv) = conn.accept_bi().await?;

    let PairMsg::Spake(theirs) = read_msg(&mut recv).await? else {
        return Err("expected spake".into());
    };
    let (state, ours) = spake_start(&code);
    write_msg(&mut send, &PairMsg::Spake(ours)).await?;
    let key = state.finish(&theirs).map_err(|e| format!("spake: {e:?}"))?;

    let PairMsg::Confirm(tag) = read_msg(&mut recv).await? else {
        return Err("expected confirm".into());
    };
    if tag != confirm_tag(&key, b"joiner", &host, &joiner) {
        write_msg(&mut send, &PairMsg::Rejected).await?;
        send.finish()?;
        let too_many = {
            let mut pairing = inner.pairing.lock().unwrap();
            pairing.as_mut().is_some_and(|p| {
                p.failures += 1;
                p.failures >= MAX_PAIR_FAILURES
            })
        };
        if too_many {
            inner.stop_pairing();
        }
        let _ = tokio::time::timeout(Duration::from_secs(5), conn.closed()).await;
        return Ok(());
    }
    write_msg(
        &mut send,
        &PairMsg::Confirm(confirm_tag(&key, b"host", &host, &joiner)),
    )
    .await?;
    let PairMsg::Name(name) = read_msg(&mut recv).await? else {
        return Err("expected name".into());
    };
    write_msg(&mut send, &PairMsg::Name(inner.name.clone())).await?;
    send.finish()?;

    inner.store.add_peer(&joiner.to_string(), &name)?;
    inner.stop_pairing();
    inner.ensure_dialer(joiner);
    // Let the joiner read the last message before the connection goes away.
    let _ = tokio::time::timeout(Duration::from_secs(5), conn.closed()).await;
    Ok(())
}

/// The side that typed the code.
async fn join_pairing(inner: Arc<Inner>, host: EndpointId, code: String) -> Result<Device> {
    // Transport errors here almost always mean the host stopped pairing or went away.
    let failed = |_: BoxError| HoltError::Pairing(NOT_PAIRING.into());
    let conn = inner
        .endpoint
        .connect(host, PAIR_ALPN)
        .await
        .map_err(|e| failed(e.into()))?;
    let joiner = inner.endpoint.id();
    let (mut send, mut recv) = conn.open_bi().await.map_err(|e| failed(e.into()))?;

    let (state, ours) = spake_start(&code);
    write_msg(&mut send, &PairMsg::Spake(ours))
        .await
        .map_err(failed)?;
    let PairMsg::Spake(theirs) = read_msg(&mut recv).await.map_err(failed)? else {
        return Err(HoltError::Pairing(NOT_PAIRING.into()));
    };
    let key = state
        .finish(&theirs)
        .map_err(|e| HoltError::Pairing(format!("Pairing failed: {e:?}")))?;
    write_msg(
        &mut send,
        &PairMsg::Confirm(confirm_tag(&key, b"joiner", &host, &joiner)),
    )
    .await
    .map_err(failed)?;

    match read_msg(&mut recv).await {
        Ok(PairMsg::Confirm(tag)) if tag == confirm_tag(&key, b"host", &host, &joiner) => {}
        Ok(PairMsg::Rejected) => {
            return Err(HoltError::Pairing(
                "That code didn't match. Check the code on your other device.".into(),
            ));
        }
        _ => return Err(HoltError::Pairing(NOT_PAIRING.into())),
    }
    write_msg(&mut send, &PairMsg::Name(inner.name.clone()))
        .await
        .map_err(failed)?;
    let PairMsg::Name(name) = read_msg(&mut recv).await.map_err(failed)? else {
        return Err(HoltError::Pairing(NOT_PAIRING.into()));
    };
    conn.close(0u32.into(), b"paired");

    inner.store.add_peer(&host.to_string(), &name)?;
    inner.nearby.lock().unwrap().remove(&host);
    inner.ensure_dialer(host);
    Ok(Device {
        id: host.to_string(),
        name,
        online: false,
    })
}

async fn watch_nearby(inner: Arc<Inner>, mdns: MdnsAddressLookup) {
    let mut events = mdns.subscribe().await;
    while let Some(event) = events.next().await {
        match event {
            DiscoveryEvent::Discovered { endpoint_info, .. } => {
                let name = endpoint_info
                    .data
                    .user_data()
                    .and_then(|data| data.to_string().strip_prefix(PAIR_PREFIX).map(String::from));
                let mut nearby = inner.nearby.lock().unwrap();
                match name {
                    Some(name) => nearby.insert(endpoint_info.endpoint_id, name),
                    None => nearby.remove(&endpoint_info.endpoint_id),
                };
            }
            DiscoveryEvent::Expired { endpoint_id } => {
                inner.nearby.lock().unwrap().remove(&endpoint_id);
            }
            _ => {}
        }
    }
}

#[derive(Debug, Clone)]
struct SyncHandler(Arc<Inner>);

impl ProtocolHandler for SyncHandler {
    async fn accept(&self, conn: Connection) -> std::result::Result<(), AcceptError> {
        let _ = sync_session(self.0.clone(), conn, false).await;
        Ok(())
    }
}

#[derive(Debug, Clone)]
struct PairHandler(Arc<Inner>);

impl ProtocolHandler for PairHandler {
    async fn accept(&self, conn: Connection) -> std::result::Result<(), AcceptError> {
        let _ = host_pairing(self.0.clone(), conn).await;
        Ok(())
    }
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Inner")
            .field("id", &self.endpoint.id())
            .finish()
    }
}

async fn write_msg<T: Serialize>(send: &mut SendStream, msg: &T) -> NetResult<()> {
    let bytes = serde_json::to_vec(msg)?;
    send.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
    send.write_all(&bytes).await?;
    Ok(())
}

async fn read_msg<T: DeserializeOwned>(recv: &mut RecvStream) -> NetResult<T> {
    let mut len = [0u8; 4];
    recv.read_exact(&mut len).await?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME_BYTES {
        return Err("message too large".into());
    }
    let mut buf = vec![0; len];
    recv.read_exact(&mut buf).await?;
    Ok(serde_json::from_slice(&buf)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(name: &str) -> Arc<Node> {
        Node::start_with(Store::open(":memory:".into()).unwrap(), name.into(), true).unwrap()
    }

    fn texts(node: &Node) -> Vec<String> {
        node.inner
            .store
            .search("".into(), 100)
            .unwrap()
            .into_iter()
            .map(|c| c.text)
            .collect()
    }

    fn wait_until(what: &str, f: impl Fn() -> bool) {
        for _ in 0..100 {
            if f() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("timed out waiting for {what}");
    }

    #[test]
    fn pairs_with_the_right_code_and_syncs() {
        let (a, b) = (node("Mac A"), node("Mac B"));
        // No mDNS in tests, so tell each node where the other listens.
        a.inner.memory.add_endpoint_info(b.inner.endpoint.addr());
        b.inner.memory.add_endpoint_info(a.inner.endpoint.addr());

        let code = a.start_pairing();
        let wrong = if code == "000000" { "111111" } else { "000000" };
        let err = b.pair(a.device_id(), wrong.into()).unwrap_err();
        assert!(err.to_string().contains("didn't match"), "{err}");

        let host = b.pair(a.device_id(), code.clone()).unwrap();
        assert_eq!(host.name, "Mac A");
        assert!(
            a.inner.pairing.lock().unwrap().is_none(),
            "pairing stops after success"
        );
        wait_until("a to list b", || {
            a.devices()
                .unwrap()
                .iter()
                .any(|d| d.name == "Mac B" && d.online)
        });

        a.inner.store.add("from a".into(), None).unwrap();
        wait_until("b to get a's clip", || texts(&b) == ["from a"]);
        let incoming = b.inner.store.take_incoming_copy().unwrap();
        assert_eq!(
            (incoming.text.as_str(), incoming.device.as_str()),
            ("from a", "Mac A")
        );

        b.inner.store.add("from b".into(), None).unwrap();
        wait_until("a to get b's clip", || texts(&a) == ["from b", "from a"]);

        let id = a.inner.store.search("from b".into(), 1).unwrap()[0].id;
        a.inner.store.delete(id).unwrap();
        wait_until("b to drop the deleted clip", || texts(&b) == ["from a"]);
    }

    #[test]
    fn unpaired_devices_get_nothing() {
        let (a, b) = (node("Mac A"), node("Stranger"));
        b.inner.memory.add_endpoint_info(a.inner.endpoint.addr());
        a.inner.store.add("secret".into(), None).unwrap();
        // b claims to be paired on its side only, and dials a.
        b.inner.store.add_peer(&a.device_id(), "Mac A").unwrap();
        let inner = b.inner.clone();
        let a_id = a.inner.endpoint.id();
        b.rt.spawn(async move {
            if let Ok(conn) = inner.endpoint.connect(a_id, SYNC_ALPN).await {
                let _ = sync_session(inner, conn, true).await;
            }
        });
        std::thread::sleep(Duration::from_secs(2));
        assert!(texts(&b).is_empty());
    }

    /// Same flow as the Mac app: find the other device over mDNS, pair, sync.
    /// Uses the real network, so it's skipped by default.
    /// Run with `cargo test -- --ignored real_network`.
    #[test]
    #[ignore]
    fn real_network() {
        let start =
            |name: &str| Node::start(Store::open(":memory:".into()).unwrap(), name.into()).unwrap();
        let (a, b) = (start("Mac A"), start("Mac B"));
        let code = a.start_pairing();
        wait_until("b to see a nearby", || {
            b.nearby().iter().any(|d| d.name == "Mac A")
        });
        let host = b.nearby().into_iter().find(|d| d.name == "Mac A").unwrap();
        b.pair(host.id, code).unwrap();
        wait_until("a and b to connect", || {
            a.devices().unwrap().iter().any(|d| d.online)
        });
        a.inner
            .store
            .add("over the real network".into(), None)
            .unwrap();
        wait_until("b to get the clip", || {
            texts(&b) == ["over the real network"]
        });
    }

    #[test]
    fn too_many_wrong_codes_stop_pairing() {
        let (a, b) = (node("Mac A"), node("Mac B"));
        b.inner.memory.add_endpoint_info(a.inner.endpoint.addr());
        let code = a.start_pairing();
        let wrong = if code == "000000" { "111111" } else { "000000" };
        for _ in 0..MAX_PAIR_FAILURES {
            assert!(b.pair(a.device_id(), wrong.into()).is_err());
        }
        assert!(a.inner.pairing.lock().unwrap().is_none());
        let err = b.pair(a.device_id(), code).unwrap_err();
        assert!(err.to_string().contains("still showing its code"), "{err}");
    }
}
