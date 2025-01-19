/// Example application demonstrating the S3 client library usage.
///
/// This example shows:
/// - Client initialization with environment-based configuration
/// - Basic bucket operations (create/delete)
/// - Object lifecycle (upload/download/delete)
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
const s3 = @import("s3");
const S3Client = s3.S3Client;
const S3Config = s3.S3Config;
const S3Error = s3.S3Error;

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get environment variables for configuration
    const access_key = try getEnvVarOrDefault("AWS_ACCESS_KEY_ID", "minioadmin");
    const secret_key = try getEnvVarOrDefault("AWS_SECRET_ACCESS_KEY", "minioadmin");
    const region = try getEnvVarOrDefault("AWS_REGION", "us-east-1");
    const endpoint = try getEnvVarOrDefault("S3_ENDPOINT", "http://localhost:9000");

    // Initialize S3 client with configuration from environment
    const config = S3Config{
        .access_key_id = access_key,
        .secret_access_key = secret_key,
        .region = region,
        .endpoint = endpoint,
    };

    var client = try S3Client.init(allocator, config);
    defer client.deinit();

    // Demonstrate bucket creation with error handling
    const bucket_name = "test-bucket";
    std.debug.print("Creating bucket '{s}'...\n", .{bucket_name});
    client.createBucket(bucket_name) catch |err| switch (err) {
        error.InvalidResponse => {
            std.debug.print("Bucket might already exist, continuing...\n", .{});
        },
        else => return err,
    };

    // Demonstrate object upload
    const key = "hello.txt";
    const content = "Hello from Zig S3 Client!";
    std.debug.print("Uploading object '{s}'...\n", .{key});
    try client.putObject(bucket_name, key, content);

    // Demonstrate object download and content verification
    std.debug.print("Downloading object '{s}'...\n", .{key});
    const downloaded = try client.getObject(bucket_name, key);
    defer allocator.free(downloaded);

    if (!std.mem.eql(u8, downloaded, content)) {
        std.debug.print("Error: Content mismatch!\n", .{});
        std.debug.print("Expected: {s}\n", .{content});
        std.debug.print("Got: {s}\n", .{downloaded});
        return error.ContentMismatch;
    }
    std.debug.print("Content verified successfully!\n", .{});

    // Demonstrate error handling for non-existent objects
    std.debug.print("Testing error handling with non-existent object...\n", .{});
    _ = client.getObject(bucket_name, "nonexistent.txt") catch |err| switch (err) {
        error.ObjectNotFound => {
            std.debug.print("Object not found (expected error)\n", .{});
        },
        else => return err,
    };

    // Clean up resources
    std.debug.print("Cleaning up...\n", .{});
    try client.deleteObject(bucket_name, key);
    try client.deleteBucket(bucket_name);
    std.debug.print("Done!\n", .{});
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
