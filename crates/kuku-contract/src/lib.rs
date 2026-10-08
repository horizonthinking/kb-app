// Connect codegen under src/generated is not linted upstream; Clippy 1.98 fires this lint 80 times there.
#![allow(clippy::result_large_err)]

#[path = "generated/buffa/mod.rs"]
pub mod proto;

#[path = "generated/connect/mod.rs"]
pub mod connect;

// Re-export the proto runtime crates so consumers don't have to depend on
// them directly. Generated code references types like `::buffa::EnumValue`
// and `::buffa_types::google::protobuf::Struct`; downstream callers reach
// them via `kuku_contract::buffa` / `kuku_contract::buffa_types`.
pub use buffa;
pub use buffa_types;
