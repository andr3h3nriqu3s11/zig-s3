# S3 Client for Zig

A simple and efficient S3 client library for Zig, supporting AWS S3 and
S3-compatible services.

## Features

- Basic S3 operations (create/delete buckets, upload/download objects)
- AWS Signature V4 authentication
- Support for custom endpoints (MinIO, LocalStack, etc.)
- Pagination support for listing objects
- Convenient upload helpers for different content types
- Memory-safe implementation using Zig's standard library

## Installation

Add the package to your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .s3 = .{
            .url = "https://github.com/your-username/zig-s3/archive/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

## Quick Start

```zig
const std = @import("std");
const s3 = @import("s3");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize client
    var client = try s3.S3Client.init(allocator, .{
        .access_key_id = "your-key",
        .secret_access_key = "your-secret",
        .region = "us-east-1",
    });
    defer client.deinit();

    // Create bucket
    try client.createBucket("my-bucket");

    // Upload different types of content using the uploader helper
    var uploader = client.uploader();

    // Upload string content
    try uploader.uploadString("my-bucket", "hello.txt", "Hello, S3!");

    // Upload JSON data
    const config = .{
        .app_name = "example",
        .version = "1.0.0",
    };
    try uploader.uploadJson("my-bucket", "config.json", config);

    // Upload a file from the filesystem
    try uploader.uploadFile("my-bucket", "data/image.jpg", "local/path/to/image.jpg");

    // List objects
    const objects = try client.listObjects("my-bucket", .{
        .prefix = "data/",
        .max_keys = 100,
    });
    defer {
        for (objects) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(objects);
    }

    // Download object
    const data = try client.getObject("my-bucket", "hello.txt");
    defer allocator.free(data);
}
```

## API Reference

### S3Client

The main client interface for S3 operations.

```zig
const client = try s3.S3Client.init(allocator, .{
    .access_key_id = "your-key",
    .secret_access_key = "your-secret",
    .region = "us-east-1",
    .endpoint = "http://localhost:9000", // Optional, for S3-compatible services
});
```

### Bucket Operations

- `createBucket(bucket_name: []const u8) !void`
- `deleteBucket(bucket_name: []const u8) !void`
- `listBuckets() ![]BucketInfo`

### Object Operations

- `putObject(bucket_name: []const u8, key: []const u8, data: []const u8) !void`
- `getObject(bucket_name: []const u8, key: []const u8) ![]const u8`
- `deleteObject(bucket_name: []const u8, key: []const u8) !void`
- `listObjects(bucket_name: []const u8, options: ListObjectsOptions) ![]ObjectInfo`

### ObjectUploader

A helper for uploading different types of content:

```zig
var uploader = client.uploader();

// Upload string content
try uploader.uploadString("my-bucket", "hello.txt", "Hello, World!");

// Upload JSON data
const data = .{ .name = "example", .value = 42 };
try uploader.uploadJson("my-bucket", "data.json", data);

// Upload file from filesystem
try uploader.uploadFile("my-bucket", "image.jpg", "path/to/local/image.jpg");
```

## Error Handling

The library uses Zig's error union type for robust error handling. Common errors
include:

- `S3Error.InvalidCredentials`: Invalid AWS credentials
- `S3Error.BucketNotFound`: Requested bucket doesn't exist
- `S3Error.ObjectNotFound`: Requested object doesn't exist
- `S3Error.ConnectionFailed`: Network or connection issues
- `S3Error.InvalidResponse`: Unexpected response from S3 service

## Testing

Run the test suite:

```bash
zig test src/main.zig
```

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- AWS S3 Documentation
- MinIO Documentation
- Zig Standard Library
