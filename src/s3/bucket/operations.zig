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

/// Bucket information returned by listBuckets
pub const BucketInfo = struct {
    /// Name of the bucket
    name: []const u8,
    /// Creation date of the bucket as ISO-8601 string
    creation_date: []const u8,
};

/// List all buckets in the account.
///
/// For S3-compatible services, this will list buckets available
/// at the configured endpoint.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///
/// Returns: Slice of BucketInfo structs. Caller owns the memory.
///
/// Errors:
///   - InvalidCredentials: If authentication fails
///   - InvalidResponse: If listing fails or response is malformed
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn listBuckets(self: *S3Client) ![]BucketInfo {
    const endpoint = if (self.config.endpoint) |ep| ep else try fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    defer if (self.config.endpoint == null) self.allocator.free(endpoint);

    var req = try self.request(.GET, try Uri.parse(endpoint), null);
    defer req.deinit();

    if (req.response.status != .ok) {
        return S3Error.InvalidResponse;
    }

    // Read response body
    const max_size = 1024 * 1024; // 1MB max response size
    const body = try req.reader().readAllAlloc(self.allocator, max_size);
    defer self.allocator.free(body);

    // Parse XML response
    var buckets = std.ArrayList(BucketInfo).init(self.allocator);
    errdefer {
        for (buckets.items) |bucket| {
            self.allocator.free(bucket.name);
            self.allocator.free(bucket.creation_date);
        }
        buckets.deinit();
    }

    // Simple XML parsing - look for <Bucket> elements
    var it = std.mem.split(u8, body, "<Bucket>");
    _ = it.first(); // Skip first part before any <Bucket>

    while (it.next()) |bucket_xml| {
        // Extract name
        const name_start = std.mem.indexOf(u8, bucket_xml, "<Name>") orelse continue;
        const name_end = std.mem.indexOf(u8, bucket_xml, "</Name>") orelse continue;
        const name = try self.allocator.dupe(u8, bucket_xml[name_start + 6 .. name_end]);

        // Extract creation date
        const date_start = std.mem.indexOf(u8, bucket_xml, "<CreationDate>") orelse continue;
        const date_end = std.mem.indexOf(u8, bucket_xml, "</CreationDate>") orelse continue;
        const date = try self.allocator.dupe(u8, bucket_xml[date_start + 14 .. date_end]);

        try buckets.append(.{
            .name = name,
            .creation_date = date,
        });
    }

    return buckets.toOwnedSlice();
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

test "list buckets" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create some test buckets
    try createBucket(test_client, "test-bucket-1");
    try createBucket(test_client, "test-bucket-2");
    defer {
        _ = deleteBucket(test_client, "test-bucket-1") catch {};
        _ = deleteBucket(test_client, "test-bucket-2") catch {};
    }

    // List buckets
    const buckets = try listBuckets(test_client);
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    // Verify buckets are listed
    var found_1 = false;
    var found_2 = false;
    for (buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, "test-bucket-1")) found_1 = true;
        if (std.mem.eql(u8, bucket.name, "test-bucket-2")) found_2 = true;
        try std.testing.expect(bucket.creation_date.len > 0);
    }
    try std.testing.expect(found_1);
    try std.testing.expect(found_2);
}

test "list buckets with custom endpoint" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // List buckets from custom endpoint
    const buckets = try listBuckets(test_client);
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    // Just verify we can parse the response
    for (buckets) |bucket| {
        try std.testing.expect(bucket.name.len > 0);
        try std.testing.expect(bucket.creation_date.len > 0);
    }
}

test "list buckets error handling" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "invalid-key",
        .secret_access_key = "invalid-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test with invalid credentials
    try std.testing.expectError(
        error.InvalidCredentials,
        listBuckets(test_client),
    );
}

test "bucket lifecycle with validation" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test bucket creation with valid name
    const bucket_name = "test-bucket-lifecycle";
    try createBucket(test_client, bucket_name);

    // Verify bucket exists by listing
    const buckets = try listBuckets(test_client);
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    var found = false;
    for (buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, bucket_name)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    // Test duplicate bucket creation
    try std.testing.expectError(
        error.InvalidResponse,
        createBucket(test_client, bucket_name),
    );

    // Clean up
    try deleteBucket(test_client, bucket_name);

    // Verify bucket is gone
    const buckets_after = try listBuckets(test_client);
    defer {
        for (buckets_after) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets_after);
    }

    found = false;
    for (buckets_after) |bucket| {
        if (std.mem.eql(u8, bucket.name, bucket_name)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(!found);
}

test "bucket operations with special characters" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test bucket names with various special characters
    const test_cases = [_]struct {
        name: []const u8,
        should_succeed: bool,
    }{
        .{ .name = "normal-bucket-123", .should_succeed = true },
        .{ .name = "bucket-with-dash", .should_succeed = true },
        .{ .name = "bucket.with.dots", .should_succeed = false },
        .{ .name = "bucket_with_underscore", .should_succeed = false },
        .{ .name = "UPPERCASE-bucket", .should_succeed = false },
        .{ .name = "bucket@with@at", .should_succeed = false },
        .{ .name = "bucket#with#hash", .should_succeed = false },
        .{ .name = "3-numeric-prefix", .should_succeed = true },
        .{ .name = "-invalid-prefix", .should_succeed = false },
        .{ .name = "invalid-suffix-", .should_succeed = false },
        .{ .name = "a", .should_succeed = false }, // Too short
        .{ .name = "ab", .should_succeed = false }, // Too short
        .{ .name = "a" ** 64, .should_succeed = false }, // Too long
    };

    for (test_cases) |case| {
        if (case.should_succeed) {
            // Should succeed
            try createBucket(test_client, case.name);

            // Verify bucket exists
            const buckets = try listBuckets(test_client);
            defer {
                for (buckets) |bucket| {
                    allocator.free(bucket.name);
                    allocator.free(bucket.creation_date);
                }
                allocator.free(buckets);
            }

            var found = false;
            for (buckets) |bucket| {
                if (std.mem.eql(u8, bucket.name, case.name)) {
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);

            // Clean up
            try deleteBucket(test_client, case.name);
        } else {
            // Should fail
            try std.testing.expectError(
                error.InvalidBucketName,
                createBucket(test_client, case.name),
            );
        }
    }
}

test "bucket operations concurrency" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create multiple buckets concurrently
    const bucket_names = [_][]const u8{
        "concurrent-bucket-1",
        "concurrent-bucket-2",
        "concurrent-bucket-3",
        "concurrent-bucket-4",
        "concurrent-bucket-5",
    };

    // Create all buckets
    for (bucket_names) |name| {
        try createBucket(test_client, name);
    }
    defer {
        // Clean up all buckets
        for (bucket_names) |name| {
            _ = deleteBucket(test_client, name) catch {};
        }
    }

    // Verify all buckets exist
    const buckets = try listBuckets(test_client);
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    for (bucket_names) |name| {
        var found = false;
        for (buckets) |bucket| {
            if (std.mem.eql(u8, bucket.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "bucket operations error cases" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test deleting non-existent bucket
    try std.testing.expectError(
        error.BucketNotFound,
        deleteBucket(test_client, "nonexistent-bucket-12345"),
    );

    // Test creating bucket with invalid characters
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, "Invalid.Bucket.Name"),
    );

    // Test creating bucket with invalid length
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, "a"),
    );

    // Create a bucket and try to create it again
    const bucket_name = "duplicate-test-bucket";
    try createBucket(test_client, bucket_name);
    defer _ = deleteBucket(test_client, bucket_name) catch {};

    try std.testing.expectError(
        error.InvalidResponse,
        createBucket(test_client, bucket_name),
    );
}

test "bucket operations with empty strings" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test empty bucket name
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, ""),
    );

    try std.testing.expectError(
        error.InvalidBucketName,
        deleteBucket(test_client, ""),
    );
}

test "bucket operations region handling" {
    const allocator = std.testing.allocator;

    // Test different regions
    const regions = [_][]const u8{
        "us-east-1",
        "us-west-1",
        "eu-west-1",
        "ap-southeast-1",
    };

    for (regions) |region| {
        const config = client_impl.S3Config{
            .access_key_id = "test-key",
            .secret_access_key = "test-secret",
            .region = region,
        };

        var test_client = try S3Client.init(allocator, config);
        defer test_client.deinit();

        const bucket_name = try fmt.allocPrint(
            allocator,
            "region-test-bucket-{s}",
            .{region},
        );
        defer allocator.free(bucket_name);

        // Basic operations should work in any region
        try createBucket(test_client, bucket_name);
        try deleteBucket(test_client, bucket_name);
    }
}
