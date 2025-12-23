# TripleStore Demo

Demonstrates the RocksDB-backed graph store via `Rag.GraphStore.TripleStore`.

## Run

```bash
mix deps.get
mix run -e "TripleStoreDemo.run()"
```

## Notes

- Requires a working Rust toolchain for the TripleStore NIF.
- Uses `priv/demo_graph` for local RocksDB storage.
