/// Object operations for S3 client.
/// This module implements basic object operations like upload, download, and deletion.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;

const lib = @import("../lib.zig");
const client_impl = @import("../client/implementation.zig");
const S3Error = lib.S3Error;
const S3Client = client_impl.S3Client;

/// Upload an object to S3.
///
/// Currently supports objects up to the size of available memory.
/// For larger objects, streaming upload support is needed (TODO).
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the target bucket
///   - key: Object key (path) in the bucket
///   - data: Object content to upload
///
/// Errors:
///   - InvalidResponse: If upload fails
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn putObject(self: *S3Client, bucket_name: []const u8, key: []const u8, data: []const u8) !void {
    const endpoint = if (self.config.endpoint) |ep| ep else try fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    defer if (self.config.endpoint == null) self.allocator.free(endpoint);

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ endpoint, bucket_name, key });
    defer self.allocator.free(uri_str);

    var req = try self.request(.PUT, try Uri.parse(uri_str), data);
    defer req.deinit();

    if (req.response.status != .ok) {
        return S3Error.InvalidResponse;
    }
}

/// Download an object from S3.
///
/// Currently limited to objects up to 1MB in size.
/// For larger objects, streaming download support is needed (TODO).
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket containing the object
///   - key: Object key (path) in the bucket
///
/// Returns: Object content as a slice. Caller owns the memory.
///
/// Errors:
///   - ObjectNotFound: If the object doesn't exist
///   - BucketNotFound: If the bucket doesn't exist
///   - InvalidResponse: If download fails
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn getObject(self: *S3Client, bucket_name: []const u8, key: []const u8) ![]const u8 {
    const endpoint = if (self.config.endpoint) |ep| ep else try fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    defer if (self.config.endpoint == null) self.allocator.free(endpoint);

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ endpoint, bucket_name, key });
    defer self.allocator.free(uri_str);

    var req = try self.request(.GET, try Uri.parse(uri_str), null);
    defer req.deinit();

    if (req.response.status == .not_found) {
        return S3Error.ObjectNotFound;
    }
    if (req.response.status != .ok) {
        return S3Error.InvalidResponse;
    }

    // TODO: Support streaming for large objects
    return try req.reader().readAllAlloc(self.allocator, 1024 * 1024); // 1MB max
}

/// Delete an object from S3.
///
/// This operation cannot be undone unless versioning is enabled on the bucket.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket containing the object
///   - key: Object key (path) to delete
///
/// Errors:
///   - InvalidResponse: If deletion fails
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn deleteObject(self: *S3Client, bucket_name: []const u8, key: []const u8) !void {
    const endpoint = if (self.config.endpoint) |ep| ep else try fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    defer if (self.config.endpoint == null) self.allocator.free(endpoint);

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ endpoint, bucket_name, key });
    defer self.allocator.free(uri_str);

    var req = try self.request(.DELETE, try Uri.parse(uri_str), null);
    defer req.deinit();

    if (req.response.status != .no_content) {
        return S3Error.InvalidResponse;
    }
}

test "object operations" {
    const allocator = std.testing.allocator;

    // Initialize test client with dummy credentials
    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test basic object lifecycle
    const test_data = "Hello, S3!";
    try putObject(test_client, "test-bucket", "test-key", test_data);

    const retrieved = try getObject(test_client, "test-bucket", "test-key");
    defer allocator.free(retrieved);
    try std.testing.expectEqualStrings(test_data, retrieved);

    try deleteObject(test_client, "test-bucket", "test-key");
}
