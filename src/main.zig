/// Example application demonstrating the S3 client library usage.
///
/// This example shows:
/// - Client initialization with environment-based configuration
/// - Basic bucket operations (create/delete)
/// - Object lifecycle (upload/download/delete)
/// - Listing buckets and objects with pagination
/// - Error handling patterns
/// - Memory management with proper cleanup
///
/// Run with default MinIO configuration:
/// ```bash
/// zig build run
/// ```
///
/// Run with custom AWS configuration:
/// ```bash
/// AWS_ACCESS_KEY_ID=your-key \
/// AWS_SECRET_ACCESS_KEY=your-secret \
/// AWS_REGION=your-region \
/// S3_ENDPOINT=https://your-endpoint \
/// zig build run
/// ```
///
/// Environment Variables:
/// - AWS_ACCESS_KEY_ID: Access key (default: "minioadmin")
/// - AWS_SECRET_ACCESS_KEY: Secret key (default: "minioadmin")
/// - AWS_REGION: AWS region (default: "us-east-1")
/// - S3_ENDPOINT: Custom endpoint URL (default: "http://localhost:9000")
const std = @import("std");
const s3 = @import("s3/lib.zig");

pub fn main() !void {
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize S3 client
    var client = try s3.S3Client.init(allocator, .{
        .access_key_id = "your-access-key",
        .secret_access_key = "your-secret-key",
        .region = "us-east-1",
        // Uncomment to use with MinIO or other S3-compatible services
        // .endpoint = "http://localhost:9000",
    });
    defer client.deinit();

    // Create a bucket
    const bucket_name = "example-bucket";
    try client.createBucket(bucket_name);

    // Create an uploader helper
    var uploader = client.uploader();

    // Upload different types of content
    try uploader.uploadString(bucket_name, "hello.txt", "Hello, S3!");

    const config = .{
        .app_name = "s3-example",
        .version = "1.0.0",
        .timestamp = @as(i64, @intCast(std.time.timestamp())),
    };
    try uploader.uploadJson(bucket_name, "config.json", config);

    // List objects in the bucket
    const objects = try client.listObjects(bucket_name, .{
        .prefix = null,
        .max_keys = 10,
    });
    defer {
        for (objects) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(objects);
    }

    // Print object information
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("\nObjects in bucket:\n");
    for (objects) |object| {
        try stdout.print("- {s} ({d} bytes)\n", .{ object.key, object.size });
    }

    // Clean up
    for (objects) |object| {
        try client.deleteObject(bucket_name, object.key);
    }
    try client.deleteBucket(bucket_name);
}

/// Helper function to get environment variables with default values.
/// Uses the page allocator since values are needed for the entire program lifetime.
fn getEnvVarOrDefault(name: []const u8, default: []const u8) ![]const u8 {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default,
        else => return err,
    };
    return value;
}
