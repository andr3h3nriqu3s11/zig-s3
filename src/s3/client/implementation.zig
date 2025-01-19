/// S3 client implementation.
/// Handles authentication, request signing, and HTTP communication with S3 services.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;

const lib = @import("../lib.zig");
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
};

/// Main S3 client implementation.
/// Handles low-level HTTP communication and request signing.
pub const S3Client = struct {
    /// Memory allocator used for dynamic allocations
    allocator: Allocator,
    /// Client configuration
    config: S3Config,
    /// HTTP client for making requests
    http_client: http.Client,

    /// Initialize a new S3 client with the given configuration.
    /// Caller owns the returned client and must call deinit when done.
    /// Memory is allocated for the client instance.
    pub fn init(allocator: Allocator, config: S3Config) !*S3Client {
        const self = try allocator.create(S3Client);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .http_client = .{ .allocator = allocator },
        };
        return self;
    }

    /// Clean up resources used by the client.
    /// This includes the HTTP client and the client instance itself.
    pub fn deinit(self: *S3Client) void {
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
        var server_header_buffer: [8192]u8 = undefined; // 8kb buffer for headers

        var req = try self.http_client.open(method, uri, .{
            .server_header_buffer = &server_header_buffer,
        });

        // Add AWS authentication header
        var auth_header_buf: [256]u8 = undefined;
        const auth_header = try self.getAuthHeader(&auth_header_buf);
        req.headers.authorization = .{ .override = auth_header };

        if (body) |data| {
            req.transfer_encoding = .{ .content_length = data.len };
        }

        try req.send();

        if (body) |data| {
            var writer = req.writer();
            _ = try writer.writeAll(data);
            try req.finish();
        }

        try req.wait();
        return req;
    }

    /// Generate AWS authentication header.
    /// TODO: Implement AWS Signature V4 signing process
    /// Currently uses a basic credential format for testing.
    fn getAuthHeader(self: *S3Client, buffer: []u8) ![]const u8 {
        return fmt.bufPrint(buffer, "AWS4-HMAC-SHA256 Credential={s}", .{self.config.access_key_id});
    }
};
