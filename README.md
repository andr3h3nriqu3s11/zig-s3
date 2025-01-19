# Zig S3 Client

A lightweight S3 client implementation in Zig, supporting basic S3 operations
with AWS S3 and S3-compatible services.

## Features

### Current Implementation

- Basic S3 operations:
  - Bucket management (create/delete)
  - Object operations (put/get/delete)
- Support for custom endpoints (compatible with MinIO, LocalStack, etc.)
- Configurable region and endpoint
- Basic error handling and custom error types
- Memory safety with proper allocation and deallocation
- Comprehensive test suite
- Uses Zig's standard HTTP client
- Modular code organization

### Missing Features / TODO

- [ ] AWS Signature V4 authentication (currently only basic credential header)
- [ ] Advanced bucket operations (list, exists, policy management)
- [ ] Advanced object operations (list, copy, multipart upload)
- [ ] Streaming support for large objects
- [ ] Proper content-type handling
- [ ] Bucket/object metadata support
- [ ] Presigned URLs
- [ ] Server-side encryption
- [ ] Bucket versioning
- [ ] Object tagging
- [ ] Cross-region operations
- [ ] Retry logic and timeout configuration

## Project Structure

The project is organized into logical modules for better maintainability:

```
src/s3/
├── lib.zig            # Library's public API
├── types.zig          # Core types and client implementation
├── bucket/
│   └── operations.zig # Bucket-specific operations
└── object/
    └── operations.zig # Object-specific operations
```

### Module Responsibilities

- **types.zig**: Contains core types (`S3Error`, `S3Config`) and the base
  `S3Client` implementation with HTTP handling
- **bucket/operations.zig**: Implements bucket-specific operations
  (create/delete)
- **object/operations.zig**: Implements object-specific operations
  (put/get/delete)
- **lib.zig**: Provides a clean public API by re-exporting functionality from
  internal modules

## Installation

Add the dependency to your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .s3_client = .{
            .url = "https://github.com/your-username/zig-s3-client/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...", // Replace with actual hash
        },
    },
}
```

## Usage

### Basic Example

```zig
const std = @import("std");
const S3Client = @import("s3").S3Client;
const S3Config = @import("s3").S3Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize client
    const config = S3Config{
        .access_key_id = "your-access-key",
        .secret_access_key = "your-secret-key",
        .region = "us-east-1",
        // Optional: custom endpoint for S3-compatible services
        .endpoint = "http://localhost:9000",
    };

    var client = try S3Client.init(allocator, config);
    defer client.deinit();

    // Create a bucket
    try client.createBucket("my-bucket");

    // Upload an object
    const data = "Hello, S3!";
    try client.putObject("my-bucket", "hello.txt", data);

    // Download an object
    const retrieved = try client.getObject("my-bucket", "hello.txt");
    defer allocator.free(retrieved);

    // Delete an object
    try client.deleteObject("my-bucket", "hello.txt");

    // Delete the bucket
    try client.deleteBucket("my-bucket");
}
```

### Error Handling

The library provides custom error types through `S3Error`:

```zig
pub const S3Error = error{
    InvalidCredentials,
    ConnectionFailed,
    BucketNotFound,
    ObjectNotFound,
    InvalidResponse,
    SignatureError,
    OutOfMemory,
};
```

Example with error handling:

```zig
const object = client.getObject("bucket", "nonexistent-key") catch |err| switch (err) {
    error.ObjectNotFound => {
        std.debug.print("Object not found\n", .{});
        return;
    },
    error.ConnectionFailed => {
        std.debug.print("Connection failed\n", .{});
        return;
    },
    else => return err,
};
defer allocator.free(object);
```

## Testing

The project includes a comprehensive test suite covering basic operations. Run
tests with:

```bash
zig build test
```

### Test Coverage

- Basic bucket operations (create/delete)
- Object operations (put/get/delete)
- Error cases (e.g., object not found)
- Custom endpoint configuration
- Memory management

## Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Build with different optimization levels
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall
```

## Contributing

Contributions are welcome! Here are some areas that need work:

1. AWS Signature V4 implementation
2. Additional S3 operations
3. Improved error handling and retry logic
4. Documentation improvements
5. Performance optimizations
6. Additional tests and examples

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file
for details.

## Acknowledgments

- Built with Zig's standard library
- Inspired by AWS SDK implementations
