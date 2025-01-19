/// Bucket operations for S3 client.
/// This module implements basic bucket management operations like creation and deletion.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;

const lib = @import("../lib.zig");
const client_impl = @import("../client/implementation.zig");
const S3Error = lib.S3Error;
const S3Client = client_impl.S3Client;

/// Create a new bucket in S3.
///
/// The bucket name must be globally unique across all AWS accounts.
/// For S3-compatible services, uniqueness might only be required within your endpoint.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket to create
///
/// Errors:
///   - InvalidResponse: If bucket creation fails (e.g., name already taken)
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn createBucket(self: *S3Client, bucket_name: []const u8) !void {
    const endpoint = if (self.config.endpoint) |ep| ep else try fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    defer if (self.config.endpoint == null) self.allocator.free(endpoint);

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}", .{ endpoint, bucket_name });
    defer self.allocator.free(uri_str);

    var req = try self.request(.PUT, try Uri.parse(uri_str), null);
    defer req.deinit();

    if (req.response.status != .created) {
        return S3Error.InvalidResponse;
    }
}

/// Delete an existing bucket from S3.
///
/// The bucket must be empty before it can be deleted.
/// This operation cannot be undone.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket to delete
///
/// Errors:
///   - InvalidResponse: If bucket deletion fails (e.g., bucket not empty)
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn deleteBucket(self: *S3Client, bucket_name: []const u8) !void {
    const endpoint = if (self.config.endpoint) |ep| ep else try fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    defer if (self.config.endpoint == null) self.allocator.free(endpoint);

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}", .{ endpoint, bucket_name });
    defer self.allocator.free(uri_str);

    var req = try self.request(.DELETE, try Uri.parse(uri_str), null);
    defer req.deinit();

    if (req.response.status != .no_content) {
        return S3Error.InvalidResponse;
    }
}

test "bucket operations" {
    const allocator = std.testing.allocator;

    // Initialize test client with dummy credentials
    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test basic bucket lifecycle
    try createBucket(test_client, "test-bucket");
    try deleteBucket(test_client, "test-bucket");
}

test "bucket operations error handling" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test invalid bucket name
    const invalid_bucket = "";
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, invalid_bucket),
    );

    // Test bucket not found
    try std.testing.expectError(
        error.BucketNotFound,
        deleteBucket(test_client, "nonexistent-bucket"),
    );
}

test "bucket operations with custom endpoint" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test bucket operations with custom endpoint
    const bucket_name = "test-bucket-local";
    try createBucket(test_client, bucket_name);
    try deleteBucket(test_client, bucket_name);
}

test "bucket name validation" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test various invalid bucket names
    const invalid_names = [_][]const u8{
        "", // Empty
        "a", // Too short
        "ab", // Too short
        "ThisHasUpperCase", // Contains uppercase
        "contains.period", // Contains period
        "contains_underscore", // Contains underscore
        "a" ** 64, // Too long
    };

    for (invalid_names) |name| {
        try std.testing.expectError(
            error.InvalidBucketName,
            createBucket(test_client, name),
        );
    }

    // Test valid bucket names
    const valid_names = [_][]const u8{
        "valid-bucket-name",
        "another-valid-bucket",
        "123-numeric-prefix",
        "bucket-with-numbers-123",
    };

    for (valid_names) |name| {
        try createBucket(test_client, name);
        try deleteBucket(test_client, name);
    }
}
