import Foundation

/// A downloadable offline model pack (TRD-003 CLD-08/11). The spec is
/// pinned in code — repository, revision, file sizes — so the storage
/// warning shown before download is a number we checked, not a guess
/// discovered halfway through a 1.8 GB transfer.
public struct ModelPackSpec: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        public init(name: String, bytes: Int64) { self.name = name; self.bytes = bytes }
    }

    public let displayName: String
    public let repository: String
    public let revision: String
    public let license: String
    public let files: [File]

    public var totalBytes: Int64 { files.map(\.bytes).reduce(0, +) }
    public var downloadURL: (String) -> URL {
        { file in URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")! }
    }

    public static let qwen3VL2B = ModelPackSpec(
        displayName: "Qwen3-VL 2B (4-bit, MLX)",
        repository: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
        revision: "9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
        license: "Apache-2.0",
        files: [
            File(name: "README.md", bytes: 599),
            File(name: "added_tokens.json", bytes: 707),
            File(name: "chat_template.jinja", bytes: 5_292),
            File(name: "chat_template.json", bytes: 5_502),
            File(name: "config.json", bytes: 7_137),
            File(name: "generation_config.json", bytes: 269),
            File(name: "merges.txt", bytes: 1_671_853),
            File(name: "model.safetensors", bytes: 1_782_040_921),
            File(name: "model.safetensors.index.json", bytes: 82_780),
            File(name: "preprocessor_config.json", bytes: 782),
            File(name: "special_tokens_map.json", bytes: 613),
            File(name: "tokenizer.json", bytes: 11_422_654),
            File(name: "tokenizer_config.json", bytes: 5_445),
            File(name: "video_preprocessor_config.json", bytes: 817),
            File(name: "vocab.json", bytes: 2_776_833),
        ])
}
