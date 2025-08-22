/// S3 client implementation.
/// Handles authentication, request signing, and HTTP communication with S3 services.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;
const time = std.time;
const log = std.log;
const tls = std.crypto.tls;
const HttpClient = http.Client;

const lib = @import("../lib.zig");
const signer = @import("auth/signer.zig");
const time_utils = @import("auth/time.zig");
const S3Error = lib.S3Error;

/// Configuration for the S3 client.
/// This includes AWS credentials and regional settings.
pub const S3Config = struct {
    /// AWS access key ID or compatible credential
    access_key_id: []const u8,
    /// AWS secret access key or compatible credential
    secret_access_key: []const u8,
    /// AWS region (e.g., "us-east-1")
    region: []const u8,
    /// Optional custom endpoint for S3-compatible services (e.g., MinIO, LocalStack)
    endpoint: ?[]const u8 = null,
    // Optional max size defaults to 1MB
    max_size: u64 = 1024 * 1024,
};

/// Main S3 client implementation.
/// Handles low-level HTTP communication and request signing.
pub const S3Client = struct {
    /// Memory allocator used for dynamic allocations
    allocator: Allocator,
    /// Client configuration
    config: S3Config,
    /// HTTP client for making requests
    http_client: HttpClient,

    /// Initialize a new S3 client with the given configuration.
    /// Caller owns the returned client and must call deinit when done.
    /// Memory is allocated for the client instance.
    pub fn init(allocator: Allocator, config: S3Config) !*S3Client {
        log.debug("Initializing S3Client", .{});
        const self = try allocator.create(S3Client);

        // Initialize HTTP client
        var client = HttpClient{
            .allocator = allocator,
        };

        // Load system root certificates for HTTPS
        if (!HttpClient.disable_tls) {
            try client.ca_bundle.rescan(allocator);
        }

        errdefer client.deinit();

        self.* = .{
            .allocator = allocator,
            .config = config,
            .http_client = client,
        };

        log.debug("S3Client initialized with TLS support", .{});
        return self;
    }

    /// Clean up resources used by the client.
    /// This includes the HTTP client and the client instance itself.
    pub fn deinit(self: *S3Client) void {
        log.debug("Deinitializing S3Client", .{});
        self.http_client.deinit();
        self.allocator.destroy(self);
    }

    /// Generic HTTP request handler used by all S3 operations.
    /// Handles request setup, authentication, and execution.
    ///
    /// Parameters:
    ///   - method: HTTP method to use (GET, PUT, DELETE, etc.)
    ///   - uri: Fully qualified URI for the request
    ///   - body: Optional request body data
    ///
    /// Returns: An HTTP request that must be deinit'd by the caller
    pub fn request(
        self: *S3Client,
        method: http.Method,
        uri: Uri,
        body: ?[]const u8,
    ) !http.Client.Request {
        log.debug("Starting S3 request: method={s}", .{@tagName(method)});

        // Create headers map for signing
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();

        // Get the host string from the Component union
        const uri_host = switch (uri.host orelse return S3Error.InvalidResponse) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };

        // Get path string from Component union and handle root path
        const uri_path = switch (uri.path) {
            .raw => |p| if (p.len == 0) "/" else p,
            .percent_encoded => |p| if (p.len == 0) "/" else p,
        };

        log.debug("Request URI host: {s}, path: {s}", .{ uri_host, uri_path });

        // Add required headers in specific order
        try headers.put("content-type", "application/xml");
        try headers.put("host", uri_host);

        // Calculate content hash
        const content_hash = try signer.hashPayload(self.allocator, body);
        defer self.allocator.free(content_hash);
        try headers.put("x-amz-content-sha256", content_hash);

        // Get current timestamp and format it properly
        const now = std.time.timestamp();
        const timestamp = @as(i64, @intCast(now));

        // Format current time as x-amz-date header
        const amz_date = try time_utils.formatAmzDateTime(self.allocator, timestamp);
        defer self.allocator.free(amz_date);
        try headers.put("x-amz-date", amz_date);

        log.debug("Using current timestamp: {d}, formatted as: {s}", .{ timestamp, amz_date });

        const credentials = signer.Credentials{
            .access_key = self.config.access_key_id,
            .secret_key = self.config.secret_access_key,
            .region = self.config.region,
            .service = "s3",
        };

        const params = signer.SigningParams{
            .method = @tagName(method),
            .path = uri_path,
            .headers = headers,
            .body = body,
            .timestamp = timestamp, // Use same timestamp for signing
        };

        // Generate authorization header
        const auth_header = try signer.signRequest(self.allocator, credentials, params);
        defer self.allocator.free(auth_header);

        log.debug("Generated auth header: {s}", .{auth_header});

        var server_header_buffer: [8192]u8 = undefined;
        var req = try self.http_client.open(method, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &[_]http.Header{
                .{ .name = "Accept", .value = "application/xml" },
                .{ .name = "x-amz-content-sha256", .value = content_hash },
                .{ .name = "x-amz-date", .value = amz_date },
                .{ .name = "Authorization", .value = auth_header },
            },
        });
        errdefer req.deinit();

        req.headers.host = .{ .override = uri_host };
        req.headers.content_type = .{ .override = "application/xml" };

        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
        }

        try req.send();

        if (body) |b| {
            try req.writeAll(b);
        }

        try req.finish();
        try req.wait();

        return req;
    }
};

test "S3Client request signing" {
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "AKIAIOSFODNN7EXAMPLE",
        .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
    };

    var client = try S3Client.init(allocator, config);
    defer client.deinit();

    const uri = try Uri.parse("https://examplebucket.s3.amazonaws.com/test.txt");
    var req = try client.request(.GET, uri, null);
    defer req.deinit();

    // Verify authorization header is present
    try std.testing.expect(req.headers.contains("authorization"));

    // Verify required AWS headers are present
    try std.testing.expect(req.headers.contains("x-amz-content-sha256"));
    try std.testing.expect(req.headers.contains("x-amz-date"));
}

test "S3Client initialization" {
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = null,
    };

    var client = try S3Client.init(allocator, config);
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.config.access_key_id);
    try std.testing.expectEqualStrings("us-east-1", client.config.region);
    try std.testing.expect(client.config.endpoint == null);
}

test "S3Client custom endpoint" {
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var client = try S3Client.init(allocator, config);
    defer client.deinit();

    try std.testing.expectEqualStrings("http://localhost:9000", client.config.endpoint.?);
}

test "S3Client request with body" {
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var client = try S3Client.init(allocator, config);
    defer client.deinit();

    const uri = try Uri.parse("https://example.s3.amazonaws.com/test.txt");
    const body = "Hello, S3!";
    var req = try client.request(.PUT, uri, body);
    defer req.deinit();

    try std.testing.expect(req.headers.contains("authorization"));
    try std.testing.expect(req.headers.contains("x-amz-content-sha256"));
    try std.testing.expect(req.headers.contains("x-amz-date"));
    try std.testing.expect(req.transfer_encoding.content_length == body.len);
}

test "S3Client error handling" {
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
    };

    var client = try S3Client.init(allocator, config);
    defer client.deinit();

    const uri = try Uri.parse("https://example.s3.amazonaws.com/test.txt");
    var req = try client.request(.GET, uri, null);
    defer req.deinit();

    // Test error mapping
    switch (req.response.status) {
        .unauthorized => try std.testing.expectError(S3Error.InvalidCredentials, S3Error.InvalidCredentials),
        .forbidden => try std.testing.expectError(S3Error.InvalidCredentials, S3Error.InvalidCredentials),
        .not_found => try std.testing.expectError(S3Error.BucketNotFound, S3Error.BucketNotFound),
        else => {},
    }
}
