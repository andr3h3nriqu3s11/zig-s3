const std = @import("std");
const s3 = @import("s3");

const testing = std.testing;
const allocator = testing.allocator;

// At the top of the file, add ConnectionRefused to possible errors
const TestError = error{
    BucketNotFound,
    ConnectionRefused,
    // ... other errors ...
};

// Test configuration
const test_config = s3.S3Config{
    .access_key_id = "minioadmin", // Default MinIO credentials
    .secret_access_key = "minioadmin", // Default MinIO credentials
    .region = "us-east-1",
    .endpoint = "http://localhost:9000",
};

test "full client lifecycle" {
    // Initialize client
    var client = try s3.S3Client.init(allocator, test_config);
    defer client.deinit();

    // Create test bucket
    const bucket_name = "integration-test-bucket";
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    // List buckets and verify our bucket exists
    const buckets = try client.listBuckets();
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    var found_bucket = false;
    for (buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, bucket_name)) {
            found_bucket = true;
            break;
        }
    }
    try testing.expect(found_bucket);

    // Test object operations
    {
        var uploader = client.uploader();

        // Upload different types of content
        try uploader.uploadString(bucket_name, "hello.txt", "Hello, Integration Tests!");

        const config_data = .{
            .app = try allocator.dupe(u8, "integration-test"),
            .version = try allocator.dupe(u8, "1.0.0"),
            .timestamp = @as(i64, @intCast(std.time.timestamp())),
        };
        defer allocator.free(config_data.app);
        defer allocator.free(config_data.version);
        try uploader.uploadJson(bucket_name, "config.json", config_data);

        // Create and upload a test file
        const test_dir = "tmp_integration_test";
        std.fs.cwd().makeDir(test_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        const test_file = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "test.dat" });
        defer allocator.free(test_file);

        {
            const file = try std.fs.cwd().createFile(test_file, .{});
            defer file.close();
            try file.writeAll("Test file content");
        }

        try uploader.uploadFile(bucket_name, "files/test.dat", test_file);

        // List objects and verify
        const objects = try client.listObjects(bucket_name, .{});
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try testing.expectEqual(@as(usize, 3), objects.len);

        // Download and verify content
        const hello_content = try client.getObject(bucket_name, "hello.txt");
        defer allocator.free(hello_content);
        try testing.expectEqualStrings("Hello, Integration Tests!", hello_content);

        const config_content = try client.getObject(bucket_name, "config.json");
        defer allocator.free(config_content);

        // Parse and verify JSON
        const parsed = try std.json.parseFromSlice(
            @TypeOf(config_data),
            allocator,
            config_content,
            .{},
        );
        defer parsed.deinit();

        try testing.expectEqualStrings("integration-test", parsed.value.app);
        try testing.expectEqualStrings("1.0.0", parsed.value.version);

        // Test object deletion
        try client.deleteObject(bucket_name, "hello.txt");
        try client.deleteObject(bucket_name, "config.json");
        try client.deleteObject(bucket_name, "files/test.dat");

        // Verify objects are gone
        const remaining_objects = try client.listObjects(bucket_name, .{});
        defer {
            for (remaining_objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(remaining_objects);
        }
        try testing.expectEqual(@as(usize, 0), remaining_objects.len);
    }
}

test "error handling" {
    var client = try s3.S3Client.init(allocator, test_config);
    defer client.deinit();

    // Test non-existent bucket
    try testing.expectError(
        error.ConnectionRefused,
        client.getObject("nonexistent-bucket", "test.txt"),
    );

    // Test non-existent object
    const bucket_name = "error-test-bucket";
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    try testing.expectError(
        error.ObjectNotFound,
        client.getObject(bucket_name, "nonexistent.txt"),
    );

    // Test invalid bucket names
    try testing.expectError(
        error.InvalidBucketName,
        client.createBucket(""),
    );

    try testing.expectError(
        error.InvalidBucketName,
        client.createBucket("invalid..bucket"),
    );

    // Test invalid object keys
    try testing.expectError(
        error.InvalidObjectKey,
        client.putObject(bucket_name, "", "test"),
    );
}

test "pagination and prefixes" {
    var client = try s3.S3Client.init(allocator, test_config);
    defer client.deinit();

    const bucket_name = "pagination-test-bucket";
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    var uploader = client.uploader();

    // Create test objects with different prefixes
    const prefixes = [_][]const u8{ "folder1/", "folder2/", "folder3/" };
    var total_objects: usize = 0;

    for (prefixes) |prefix| {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const key = try std.fmt.allocPrint(
                allocator,
                "{s}file{d}.txt",
                .{ prefix, i },
            );
            defer allocator.free(key);
            const content = try std.fmt.allocPrint(
                allocator,
                "Content {d}",
                .{i},
            );
            defer allocator.free(content);
            try uploader.uploadString(bucket_name, key, content);
            total_objects += 1;
        }
    }

    // Test listing with different page sizes
    {
        const page_size: u32 = 7;
        var all_objects = std.ArrayList(s3.ObjectInfo).init(allocator);
        defer {
            for (all_objects.items) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            all_objects.deinit();
        }

        var last_key: ?[]const u8 = null;
        while (true) {
            const page = try client.listObjects(bucket_name, .{
                .max_keys = page_size,
                .start_after = last_key,
            });
            defer {
                if (last_key) |key| {
                    allocator.free(key);
                }
                allocator.free(page);
            }

            if (page.len == 0) break;

            for (page) |object| {
                const key_copy = try allocator.dupe(u8, object.key);
                const lm_copy = try allocator.dupe(u8, object.last_modified);
                const etag_copy = try allocator.dupe(u8, object.etag);
                try all_objects.append(.{
                    .key = key_copy,
                    .size = object.size,
                    .last_modified = lm_copy,
                    .etag = etag_copy,
                });
            }

            if (page.len < page_size) break;
            last_key = try allocator.dupe(u8, page[page.len - 1].key);
        }

        try testing.expectEqual(total_objects, all_objects.items.len);
    }

    // Test listing with prefix
    for (prefixes) |prefix| {
        const objects = try client.listObjects(bucket_name, .{
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

        try testing.expectEqual(@as(usize, 5), objects.len);
        for (objects) |object| {
            try testing.expect(std.mem.startsWith(u8, object.key, prefix));
        }
    }

    // Clean up test objects
    for (prefixes) |prefix| {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const key = try std.fmt.allocPrint(
                allocator,
                "{s}file{d}.txt",
                .{ prefix, i },
            );
            defer allocator.free(key);
            try client.deleteObject(bucket_name, key);
        }
    }
}

test "file upload and download" {
    // Initialize client
    var client = try s3.S3Client.init(allocator, test_config);
    defer client.deinit();

    // Setup test bucket
    const bucket_name = "file-upload-test-bucket";
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    var uploader = client.uploader();

    // Test text file upload
    {
        const s3_key = "text/sample.txt";
        try uploader.uploadFile(bucket_name, s3_key, "tests/integration/assets/sample.txt");

        // Verify uploaded content
        const downloaded = try client.getObject(bucket_name, s3_key);
        defer allocator.free(downloaded);

        // Read original file for comparison
        const original_file = try std.fs.cwd().openFile("tests/integration/assets/sample.txt", .{});
        defer original_file.close();

        const original_content = try original_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(original_content);

        try testing.expectEqualStrings(original_content, downloaded);
    }

    // Test JSON file upload
    {
        const s3_key = "json/config.json";
        try uploader.uploadFile(bucket_name, s3_key, "tests/integration/assets/config.json");

        // Verify uploaded content
        const downloaded = try client.getObject(bucket_name, s3_key);
        defer allocator.free(downloaded);

        // Read original file for comparison
        const original_file = try std.fs.cwd().openFile("tests/integration/assets/config.json", .{});
        defer original_file.close();

        const original_content = try original_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(original_content);

        try testing.expectEqualStrings(original_content, downloaded);

        // Verify JSON parsing still works
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            downloaded,
            .{},
        );
        defer parsed.deinit();

        try testing.expect(parsed.value.object.get("name").?.string.len > 0);
        try testing.expect(parsed.value.object.get("version").?.string.len > 0);
    }

    // Test file metadata and listing
    {
        const objects = try client.listObjects(bucket_name, .{});
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try testing.expectEqual(@as(usize, 2), objects.len);

        // Verify objects are listed with correct prefixes
        var found_text = false;
        var found_json = false;
        for (objects) |object| {
            if (std.mem.startsWith(u8, object.key, "text/")) found_text = true;
            if (std.mem.startsWith(u8, object.key, "json/")) found_json = true;
        }
        try testing.expect(found_text);
        try testing.expect(found_json);
    }

    // Cleanup: Delete the uploaded files
    try client.deleteObject(bucket_name, "text/sample.txt");
    try client.deleteObject(bucket_name, "json/config.json");

    // Verify deletion
    const remaining = try client.listObjects(bucket_name, .{});
    defer {
        for (remaining) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(remaining);
    }
    try testing.expectEqual(@as(usize, 0), remaining.len);
}
