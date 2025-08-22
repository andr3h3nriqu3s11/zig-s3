/// Object operations for S3 client.
/// This module implements basic object operations like upload, download, and deletion.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;
const fs = std.fs;

const lib = @import("../lib.zig");
const client_impl = @import("../client/implementation.zig");
const bucket_ops = @import("../bucket/operations.zig");
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

    return try req.reader().readAllAlloc(self.allocator, self.config.max_size);
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

/// Object information returned by listObjects
pub const ObjectInfo = struct {
    /// Key (path) of the object
    key: []const u8,
    /// Size of the object in bytes
    size: u64,
    /// Last modified timestamp as ISO-8601 string
    last_modified: []const u8,
    /// ETag of the object (usually MD5 of content)
    etag: []const u8,
};

/// Options for listing objects
pub const ListObjectsOptions = struct {
    /// Filter objects by prefix
    prefix: ?[]const u8 = null,
    /// Maximum number of objects to return (1-1000)
    max_keys: ?u32 = null,
    /// Start listing from this key (for pagination)
    start_after: ?[]const u8 = null,
};

/// List objects in a bucket.
///
/// This implements the S3 ListObjectsV2 API.
/// Results are sorted by key in lexicographical order.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket to list
///   - options: Optional listing parameters (prefix, pagination)
///
/// Returns: Slice of ObjectInfo structs. Caller owns the memory.
///
/// Errors:
///   - BucketNotFound: If the bucket doesn't exist
///   - InvalidResponse: If listing fails or response is malformed
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn listObjects(
    self: *S3Client,
    bucket_name: []const u8,
    options: ListObjectsOptions,
) ![]ObjectInfo {
    const endpoint = if (self.config.endpoint) |ep| ep else try fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    defer if (self.config.endpoint == null) self.allocator.free(endpoint);

    // Build query string
    var query = std.ArrayList(u8).init(self.allocator);
    defer query.deinit();

    try query.appendSlice("list-type=2"); // Use ListObjectsV2

    if (options.prefix) |prefix| {
        try query.appendSlice("&prefix=");
        try query.appendSlice(prefix);
    }

    if (options.max_keys) |max_keys| {
        try query.appendSlice("&max-keys=");
        try query.writer().print("{d}", .{max_keys});
    }

    if (options.start_after) |start_after| {
        try query.appendSlice("&start-after=");
        try query.appendSlice(start_after);
    }

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}?{s}", .{
        endpoint,
        bucket_name,
        query.items,
    });
    defer self.allocator.free(uri_str);

    var req = try self.request(.GET, try Uri.parse(uri_str), null);
    defer req.deinit();

    if (req.response.status == .not_found) {
        return S3Error.BucketNotFound;
    }
    if (req.response.status != .ok) {
        return S3Error.InvalidResponse;
    }

    // Read response body
    const max_size = 1024 * 1024; // 1MB max response size
    const body = try req.reader().readAllAlloc(self.allocator, max_size);
    defer self.allocator.free(body);

    // Parse XML response
    var objects = std.ArrayList(ObjectInfo).init(self.allocator);
    errdefer {
        for (objects.items) |object| {
            self.allocator.free(object.key);
            self.allocator.free(object.last_modified);
            self.allocator.free(object.etag);
        }
        objects.deinit();
    }

    // Simple XML parsing - look for <Contents> elements
    var it = std.mem.splitSequence(u8, body, "<Contents>");
    _ = it.first(); // Skip first part before any <Contents>

    while (it.next()) |object_xml| {
        // Extract key
        const key_start = std.mem.indexOf(u8, object_xml, "<Key>") orelse continue;
        const key_end = std.mem.indexOf(u8, object_xml, "</Key>") orelse continue;
        const key = try self.allocator.dupe(u8, object_xml[key_start + 5 .. key_end]);

        // Extract size
        const size_start = std.mem.indexOf(u8, object_xml, "<Size>") orelse continue;
        const size_end = std.mem.indexOf(u8, object_xml, "</Size>") orelse continue;
        const size = try std.fmt.parseInt(u64, object_xml[size_start + 6 .. size_end], 10);

        // Extract last modified
        const lm_start = std.mem.indexOf(u8, object_xml, "<LastModified>") orelse continue;
        const lm_end = std.mem.indexOf(u8, object_xml, "</LastModified>") orelse continue;
        const last_modified = try self.allocator.dupe(u8, object_xml[lm_start + 13 .. lm_end]);

        // Extract ETag
        const etag_start = std.mem.indexOf(u8, object_xml, "<ETag>") orelse continue;
        const etag_end = std.mem.indexOf(u8, object_xml, "</ETag>") orelse continue;
        const etag = try self.allocator.dupe(u8, object_xml[etag_start + 6 .. etag_end]);

        try objects.append(.{
            .key = key,
            .size = size,
            .last_modified = last_modified,
            .etag = etag,
        });
    }

    return objects.toOwnedSlice();
}

pub const ObjectUploader = struct {
    client: *S3Client,

    pub fn init(client: *S3Client) ObjectUploader {
        return .{
            .client = client,
        };
    }

    /// Uploads a file from the filesystem to S3
    /// Handles the file reading and binary conversion automatically
    pub fn uploadFile(
        self: *ObjectUploader,
        bucket_name: []const u8,
        key: []const u8,
        file_path: []const u8,
    ) !void {
        // Open the file
        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();

        // Get file size
        const file_size = try file.getEndPos();

        // Allocate buffer and read file
        const buffer = try self.client.allocator.alloc(u8, file_size);
        defer self.client.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read != file_size) {
            return error.IncompleteRead;
        }

        // Upload the binary data
        try putObject(self.client, bucket_name, key, buffer);
    }

    /// Uploads string data to S3
    /// Automatically converts the string to binary
    pub fn uploadString(
        self: *ObjectUploader,
        bucket_name: []const u8,
        key: []const u8,
        content: []const u8,
    ) !void {
        // String data is already in []const u8 format
        try putObject(self.client, bucket_name, key, content);
    }

    /// Uploads JSON data to S3
    /// Handles the serialization automatically
    pub fn uploadJson(
        self: *ObjectUploader,
        bucket_name: []const u8,
        key: []const u8,
        data: anytype,
    ) !void {
        // Create a buffer for JSON string
        var buffer = std.ArrayList(u8).init(self.client.allocator);
        defer buffer.deinit();

        // Serialize to JSON
        try std.json.stringify(data, .{}, buffer.writer());

        // Upload the JSON data
        try putObject(self.client, bucket_name, key, buffer.items);
    }
};

test "upload different types" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    var uploader = ObjectUploader.init(&test_client);

    // File upload
    try uploader.uploadFile(
        "my-bucket",
        "images/photo.jpg",
        "path/to/local/photo.jpg",
    );

    // String upload
    try uploader.uploadString(
        "my-bucket",
        "text/hello.txt",
        "Hello, World!",
    );

    // JSON upload
    const json_data = .{
        .name = "John",
        .age = 30,
    };
    try uploader.uploadJson(
        "my-bucket",
        "data/user.json",
        json_data,
    );
}

test "list objects basic" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-objects";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "test1.txt", .content = "Hello 1" },
        .{ .key = "test2.txt", .content = "Hello 2" },
        .{ .key = "folder/test3.txt", .content = "Hello 3" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        for (test_objects) |obj| {
            _ = deleteObject(test_client, bucket_name, obj.key) catch {};
        }
    }

    // List all objects
    const objects = try listObjects(test_client, bucket_name, .{});
    defer {
        for (objects) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(objects);
    }

    try std.testing.expectEqual(test_objects.len, objects.len);

    // Verify each object
    for (objects) |object| {
        var found = false;
        for (test_objects) |test_obj| {
            if (std.mem.eql(u8, object.key, test_obj.key)) {
                found = true;
                try std.testing.expectEqual(test_obj.content.len, object.size);
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "list objects with prefix" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-prefix";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "folder1/test1.txt", .content = "Hello 1" },
        .{ .key = "folder1/test2.txt", .content = "Hello 2" },
        .{ .key = "folder2/test3.txt", .content = "Hello 3" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        for (test_objects) |obj| {
            _ = deleteObject(test_client, bucket_name, obj.key) catch {};
        }
    }

    // List objects with prefix
    const objects = try listObjects(test_client, bucket_name, .{
        .prefix = "folder1/",
    });
    defer {
        for (objects) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(objects);
    }

    try std.testing.expectEqual(@as(usize, 2), objects.len);

    // Verify each object starts with prefix
    for (objects) |object| {
        try std.testing.expect(std.mem.startsWith(u8, object.key, "folder1/"));
    }
}

test "list objects pagination" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-pagination";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create 5 test objects
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const key = try fmt.allocPrint(allocator, "test{d}.txt", .{i});
        defer allocator.free(key);
        const content = try fmt.allocPrint(allocator, "Content {d}", .{i});
        defer allocator.free(content);
        try putObject(test_client, bucket_name, key, content);
    }
    defer {
        i = 0;
        while (i < 5) : (i += 1) {
            const key = fmt.allocPrint(allocator, "test{d}.txt", .{i}) catch continue;
            defer allocator.free(key);
            _ = deleteObject(test_client, bucket_name, key) catch {};
        }
    }

    // List first page (2 objects)
    const page1 = try listObjects(test_client, bucket_name, .{
        .max_keys = 2,
    });
    defer {
        for (page1) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(page1);
    }

    try std.testing.expectEqual(@as(usize, 2), page1.len);

    // List second page using start_after
    const page2 = try listObjects(test_client, bucket_name, .{
        .max_keys = 2,
        .start_after = page1[1].key,
    });
    defer {
        for (page2) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(page2);
    }

    try std.testing.expectEqual(@as(usize, 2), page2.len);
    try std.testing.expect(!std.mem.eql(u8, page1[0].key, page2[0].key));
    try std.testing.expect(!std.mem.eql(u8, page1[1].key, page2[0].key));
}

test "list objects error cases" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test non-existent bucket
    try std.testing.expectError(
        error.BucketNotFound,
        listObjects(test_client, "nonexistent-bucket", .{}),
    );

    // Test invalid max_keys
    try std.testing.expectError(
        error.InvalidResponse,
        listObjects(test_client, "test-bucket", .{
            .max_keys = 1001, // Max allowed is 1000
        }),
    );
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

test "object operations error handling" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test object not found
    try std.testing.expectError(
        error.ObjectNotFound,
        getObject(test_client, "test-bucket", "nonexistent-key"),
    );

    // Test invalid object key
    const invalid_key = "";
    try std.testing.expectError(
        error.InvalidObjectKey,
        putObject(test_client, "test-bucket", invalid_key, "test data"),
    );
}

test "object operations with large data" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create large test data (1MB)
    const data_size = 1024 * 1024;
    var large_data = try allocator.alloc(u8, data_size);
    defer allocator.free(large_data);

    for (0..data_size) |i| {
        large_data[i] = @as(u8, @truncate(i));
    }

    // Test large object operations
    try putObject(test_client, "test-bucket", "large-file.bin", large_data);

    const retrieved = try getObject(test_client, "test-bucket", "large-file.bin");
    defer allocator.free(retrieved);

    try std.testing.expectEqualSlices(u8, large_data, retrieved);

    try deleteObject(test_client, "test-bucket", "large-file.bin");
}

test "object operations with custom endpoint" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test object operations with custom endpoint
    const test_data = "Testing with custom endpoint";
    try putObject(test_client, "test-bucket", "custom-endpoint-test.txt", test_data);

    const retrieved = try getObject(test_client, "test-bucket", "custom-endpoint-test.txt");
    defer allocator.free(retrieved);

    try std.testing.expectEqualStrings(test_data, retrieved);

    try deleteObject(test_client, "test-bucket", "custom-endpoint-test.txt");
}

test "object key validation" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Test various invalid object keys
    const invalid_keys = [_][]const u8{
        "", // Empty
        "key\nwith\nnewlines", // Contains newlines
        "key with\x00null", // Contains null byte
        "a" ** 1025, // Too long (max is 1024)
    };

    for (invalid_keys) |key| {
        try std.testing.expectError(
            error.InvalidObjectKey,
            putObject(test_client, "test-bucket", key, "test data"),
        );
    }

    // Test valid object keys
    const valid_keys = [_][]const u8{
        "valid/key.txt",
        "path/to/object.json",
        "special-chars_!@#$%^&*().txt",
        "unicode-✨.txt",
    };

    for (valid_keys) |key| {
        const test_data = "Test data";
        try putObject(test_client, "test-bucket", key, test_data);

        const retrieved = try getObject(test_client, "test-bucket", key);
        defer allocator.free(retrieved);

        try std.testing.expectEqualStrings(test_data, retrieved);

        try deleteObject(test_client, "test-bucket", key);
    }
}

test "list objects empty bucket" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create empty bucket
    const bucket_name = "test-empty-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // List objects in empty bucket
    const objects = try listObjects(test_client, bucket_name, .{});
    defer allocator.free(objects);

    try std.testing.expectEqual(@as(usize, 0), objects.len);
}

test "list objects with multiple prefixes" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    const bucket_name = "test-prefix-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create objects with different prefixes
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "folder1/a.txt", .content = "a" },
        .{ .key = "folder1/b.txt", .content = "b" },
        .{ .key = "folder2/c.txt", .content = "c" },
        .{ .key = "folder2/subfolder/d.txt", .content = "d" },
        .{ .key = "folder3/e.txt", .content = "e" },
        .{ .key = "root.txt", .content = "root" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        for (test_objects) |obj| {
            _ = deleteObject(test_client, bucket_name, obj.key) catch {};
        }
    }

    // Test different prefix scenarios
    const test_cases = [_]struct {
        prefix: []const u8,
        expected_count: usize,
    }{
        .{ .prefix = "folder1/", .expected_count = 2 },
        .{ .prefix = "folder2/", .expected_count = 2 },
        .{ .prefix = "folder2/subfolder/", .expected_count = 1 },
        .{ .prefix = "folder3/", .expected_count = 1 },
        .{ .prefix = "", .expected_count = 6 }, // All objects
        .{ .prefix = "nonexistent/", .expected_count = 0 },
    };

    for (test_cases) |case| {
        const objects = try listObjects(test_client, bucket_name, .{
            .prefix = case.prefix,
        });
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try std.testing.expectEqual(case.expected_count, objects.len);

        // Verify all objects start with prefix
        for (objects) |object| {
            if (case.prefix.len > 0) {
                try std.testing.expect(std.mem.startsWith(u8, object.key, case.prefix));
            }
        }
    }
}

test "list objects pagination with various sizes" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    const bucket_name = "test-pagination-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create 25 test objects
    const total_objects = 25;
    var i: usize = 0;
    while (i < total_objects) : (i += 1) {
        const key = try fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{i}); // pad with zeros for correct sorting
        defer allocator.free(key);
        const content = try fmt.allocPrint(allocator, "Content {d}", .{i});
        defer allocator.free(content);
        try putObject(test_client, bucket_name, key, content);
    }
    defer {
        i = 0;
        while (i < total_objects) : (i += 1) {
            const key = fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{i}) catch continue;
            defer allocator.free(key);
            _ = deleteObject(test_client, bucket_name, key) catch {};
        }
    }

    // Test different page sizes
    const page_sizes = [_]u32{ 5, 10, 15 };
    for (page_sizes) |page_size| {
        var collected_objects = std.ArrayList([]const u8).init(allocator);
        defer {
            for (collected_objects.items) |key| {
                allocator.free(key);
            }
            collected_objects.deinit();
        }

        var last_key: ?[]const u8 = null;
        while (true) {
            const page = try listObjects(test_client, bucket_name, .{
                .max_keys = page_size,
                .start_after = last_key,
            });
            defer {
                for (page) |object| {
                    if (!std.mem.eql(u8, object.key, last_key orelse "")) {
                        allocator.free(object.last_modified);
                        allocator.free(object.etag);
                    }
                }
                allocator.free(page);
            }

            if (page.len == 0) break;

            for (page) |object| {
                if (last_key == null or !std.mem.eql(u8, object.key, last_key.?)) {
                    try collected_objects.append(try allocator.dupe(u8, object.key));
                }
            }

            if (page.len < page_size) break;

            if (last_key) |key| {
                allocator.free(key);
            }
            last_key = try allocator.dupe(u8, page[page.len - 1].key);
        }

        if (last_key) |key| {
            allocator.free(key);
        }

        // Verify we got all objects and they're in order
        try std.testing.expectEqual(@as(usize, total_objects), collected_objects.items.len);
        for (collected_objects.items, 0..) |key, idx| {
            const expected = try fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{idx});
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, key);
        }
    }
}

test "list objects with special characters in prefix" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    const bucket_name = "test-special-chars";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create objects with special characters in paths
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "special!chars/test1.txt", .content = "1" },
        .{ .key = "special@chars/test2.txt", .content = "2" },
        .{ .key = "special#chars/test3.txt", .content = "3" },
        .{ .key = "special$chars/test4.txt", .content = "4" },
        .{ .key = "special chars/test5.txt", .content = "5" },
        .{ .key = "special%20chars/test6.txt", .content = "6" },
        .{ .key = "special+chars/test7.txt", .content = "7" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        for (test_objects) |obj| {
            _ = deleteObject(test_client, bucket_name, obj.key) catch {};
        }
    }

    // Test listing with various special character prefixes
    for (test_objects) |obj| {
        const prefix = obj.key[0 .. std.mem.indexOf(u8, obj.key, "/").? + 1];
        const objects = try listObjects(test_client, bucket_name, .{
            .prefix = prefix,
        });
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try std.testing.expectEqual(@as(usize, 1), objects.len);
        try std.testing.expectEqualStrings(obj.key, objects[0].key);
    }
}

test "ObjectUploader basic functionality" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create test bucket
    const bucket_name = "test-uploader";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    var uploader = ObjectUploader.init(test_client);

    // Test string upload
    const test_string = "Hello, World!";
    try uploader.uploadString(bucket_name, "test.txt", test_string);

    // Verify string upload
    const retrieved_string = try getObject(test_client, bucket_name, "test.txt");
    defer allocator.free(retrieved_string);
    try std.testing.expectEqualStrings(test_string, retrieved_string);

    // Test JSON upload
    const test_json = .{
        .name = "test",
        .value = 42,
        .tags = [_][]const u8{ "tag1", "tag2" },
    };
    try uploader.uploadJson(bucket_name, "test.json", test_json);

    // Verify JSON upload
    const retrieved_json = try getObject(test_client, bucket_name, "test.json");
    defer allocator.free(retrieved_json);

    // Parse and verify JSON content
    const parsed = try std.json.parseFromSlice(
        @TypeOf(test_json),
        allocator,
        retrieved_json,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", parsed.value.name);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.value);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try std.testing.expectEqualStrings("tag1", parsed.value.tags[0]);
    try std.testing.expectEqualStrings("tag2", parsed.value.tags[1]);

    // Clean up test objects
    try deleteObject(test_client, bucket_name, "test.txt");
    try deleteObject(test_client, bucket_name, "test.json");
}

test "ObjectUploader file operations" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    // Create test bucket
    const bucket_name = "test-file-uploader";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    var uploader = ObjectUploader.init(test_client);

    // Create a temporary test file
    const test_content = "Test file content";
    const test_filename = "test-upload.txt";

    // Create temporary directory for test files
    try std.fs.cwd().makeDir("tmp") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree("tmp") catch {};

    // Create and write test file
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "tmp", test_filename });
    defer allocator.free(file_path);

    {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }

    // Test file upload
    try uploader.uploadFile(bucket_name, "uploaded.txt", file_path);

    // Verify file upload
    const retrieved_content = try getObject(test_client, bucket_name, "uploaded.txt");
    defer allocator.free(retrieved_content);
    try std.testing.expectEqualStrings(test_content, retrieved_content);

    // Clean up test object
    try deleteObject(test_client, bucket_name, "uploaded.txt");
}

test "ObjectUploader error cases" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    var uploader = ObjectUploader.init(test_client);

    // Test non-existent bucket
    try std.testing.expectError(
        error.BucketNotFound,
        uploader.uploadString("nonexistent-bucket", "test.txt", "test"),
    );

    // Test invalid object key
    try std.testing.expectError(
        error.InvalidObjectKey,
        uploader.uploadString("test-bucket", "", "test"),
    );

    // Test non-existent file
    try std.testing.expectError(
        error.FileNotFound,
        uploader.uploadFile("test-bucket", "test.txt", "nonexistent/file.txt"),
    );

    // Test invalid JSON
    const invalid_json = .{
        .recursive = @as(*anyopaque, undefined), // Can't serialize pointer types to JSON
    };
    try std.testing.expectError(
        error.InvalidValue,
        uploader.uploadJson("test-bucket", "test.json", invalid_json),
    );
}

test "ObjectUploader with custom endpoint" {
    const allocator = std.testing.allocator;

    const config = client_impl.S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, config);
    defer test_client.deinit();

    var uploader = ObjectUploader.init(test_client);

    // Create test bucket
    const bucket_name = "test-custom-endpoint";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Test basic upload with custom endpoint
    const test_data = "Testing with custom endpoint";
    try uploader.uploadString(bucket_name, "test.txt", test_data);

    // Verify upload
    const retrieved = try getObject(test_client, bucket_name, "test.txt");
    defer allocator.free(retrieved);
    try std.testing.expectEqualStrings(test_data, retrieved);

    // Clean up
    try deleteObject(test_client, bucket_name, "test.txt");
}
