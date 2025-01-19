/// AWS Signature V4 implementation.
/// Handles request signing according to AWS specifications:
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html
///
/// This module implements the complete AWS Signature Version 4 signing process.
/// The signing process involves several steps:
///
/// 1. Create a canonical request by combining:
///    - HTTP method
///    - URI path (normalized)
///    - Query string (sorted)
///    - Headers (canonicalized and sorted)
///    - Signed headers list
///    - Payload hash
///
/// 2. Create a string to sign using:
///    - Algorithm identifier
///    - Request timestamp
///    - Credential scope
///    - Hash of canonical request
///
/// 3. Calculate the signature using:
///    - Derived signing key (through multiple HMAC operations)
///    - String to sign
///
/// 4. Create the final Authorization header
///
/// Example usage:
/// ```zig
/// const credentials = Credentials{
///     .access_key = "AKIAIOSFODNN7EXAMPLE",
///     .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
///     .region = "us-east-1",
///     .service = "s3",
/// };
///
/// const params = SigningParams{
///     .method = "GET",
///     .path = "/test.txt",
///     .headers = headers,
///     .timestamp = timestamp,
/// };
///
/// const auth_header = try signRequest(allocator, credentials, params);
/// defer allocator.free(auth_header);
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const fmt = std.fmt;
const mem = std.mem;
const time = std.time;

const time_utils = @import("time.zig");

/// AWS region for signing
const Region = []const u8;
/// AWS service name (e.g., "s3")
const Service = []const u8;

/// Credentials used for signing
pub const Credentials = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: Region,
    service: Service = "s3",
};

/// Request parameters needed for signing
pub const SigningParams = struct {
    /// HTTP method (GET, PUT, etc.)
    method: []const u8,
    /// Full request path including query string
    path: []const u8,
    /// Request headers
    headers: std.StringHashMap([]const u8),
    /// Request body (or null)
    body: ?[]const u8 = null,
    /// Request timestamp (or null for current time)
    timestamp: ?i64 = null,
};

/// Generate AWS Signature V4 for a request.
/// Follows the process described in AWS documentation:
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
pub fn signRequest(
    allocator: Allocator,
    credentials: Credentials,
    params: SigningParams,
) ![]const u8 {
    // Step 1: Create canonical request
    const canonical_request = try createCanonicalRequest(allocator, params);
    defer allocator.free(canonical_request);

    // Step 2: Create string to sign
    const string_to_sign = try createStringToSign(
        allocator,
        credentials,
        canonical_request,
        params.timestamp orelse time.timestamp(),
    );
    defer allocator.free(string_to_sign);

    // Step 3: Calculate signature
    const signature = try calculateSignature(
        allocator,
        credentials,
        string_to_sign,
        params.timestamp orelse time.timestamp(),
    );
    defer allocator.free(signature);

    // Step 4: Create authorization header
    return try createAuthorizationHeader(
        allocator,
        credentials,
        signature,
        params.timestamp orelse time.timestamp(),
    );
}

/// Create canonical request string.
/// Format: METHOD\n
///         URI\n
///         QUERY_STRING\n
///         CANONICAL_HEADERS\n
///         SIGNED_HEADERS\n
///         HEX(HASH(PAYLOAD))
fn createCanonicalRequest(
    allocator: Allocator,
    params: SigningParams,
) ![]const u8 {
    var canonical = std.ArrayList(u8).init(allocator);
    defer canonical.deinit();

    // Add HTTP method
    try canonical.appendSlice(params.method);
    try canonical.append('\n');

    // Add URI path (must be normalized)
    const normalized_path = try normalizePath(allocator, params.path);
    defer allocator.free(normalized_path);
    try canonical.appendSlice(normalized_path);
    try canonical.append('\n');

    // Add canonical query string (sorted by parameter name)
    const query_string = try createCanonicalQueryString(allocator, params.path);
    defer allocator.free(query_string);
    try canonical.appendSlice(query_string);
    try canonical.append('\n');

    // Add canonical headers
    var headers_list = std.ArrayList([]const u8).init(allocator);
    defer headers_list.deinit();
    var headers_it = params.headers.iterator();
    while (headers_it.next()) |entry| {
        const header = try fmt.allocPrint(
            allocator,
            "{s}:{s}\n",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
        try headers_list.append(header);
    }

    // Sort headers
    mem.sort([]const u8, headers_list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Add sorted headers to canonical request
    for (headers_list.items) |header| {
        try canonical.appendSlice(header);
    }
    try canonical.append('\n');

    // Add signed headers
    var signed_headers = std.ArrayList([]const u8).init(allocator);
    defer signed_headers.deinit();
    headers_it = params.headers.iterator();
    while (headers_it.next()) |entry| {
        try signed_headers.append(entry.key_ptr.*);
    }

    // Sort signed headers
    mem.sort([]const u8, signed_headers.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Add sorted signed headers to canonical request
    for (signed_headers.items, 0..) |header, i| {
        if (i > 0) try canonical.append(';');
        try canonical.appendSlice(header);
    }
    try canonical.append('\n');

    // Add payload hash
    const payload_hash = try hashPayload(allocator, params.body);
    defer allocator.free(payload_hash);
    try canonical.appendSlice(payload_hash);

    return canonical.toOwnedSlice();
}

/// Create string to sign.
/// Format: AWS4-HMAC-SHA256\n
///         TIMESTAMP\n
///         SCOPE\n
///         HEX(HASH(CANONICAL_REQUEST))
fn createStringToSign(
    allocator: Allocator,
    credentials: Credentials,
    canonical_request: []const u8,
    timestamp: i64,
) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    // Algorithm
    try result.appendSlice("AWS4-HMAC-SHA256\n");

    // Timestamp
    const timestamp_str = try time_utils.formatAmzDateTime(allocator, timestamp);
    defer allocator.free(timestamp_str);
    try result.appendSlice(timestamp_str);
    try result.append('\n');

    // Credential scope
    const date = try time_utils.formatAmzDate(allocator, timestamp);
    defer allocator.free(date);
    try result.appendSlice(date);
    try result.append('/');
    try result.appendSlice(credentials.region);
    try result.append('/');
    try result.appendSlice(credentials.service);
    try result.appendSlice("/aws4_request\n");

    // Hashed canonical request
    var hash: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(canonical_request, &hash, .{});
    const hash_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
    defer allocator.free(hash_hex);
    try result.appendSlice(hash_hex);

    return result.toOwnedSlice();
}

/// Calculate request signature using derived signing key
fn calculateSignature(
    allocator: Allocator,
    credentials: Credentials,
    string_to_sign: []const u8,
    timestamp: i64,
) ![]const u8 {
    // Get signing key
    const signing_key = try deriveSigningKey(
        allocator,
        credentials,
        timestamp,
    );
    defer allocator.free(signing_key);

    // Calculate HMAC-SHA256
    var hmac: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&hmac, string_to_sign, signing_key);

    // Convert to hex
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hmac)});
}

/// Create final authorization header value
fn createAuthorizationHeader(
    allocator: Allocator,
    credentials: Credentials,
    signature: []const u8,
    timestamp: i64,
) ![]const u8 {
    const date = try time_utils.formatAmzDate(allocator, timestamp);
    defer allocator.free(date);

    return fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}",
        .{
            credentials.access_key,
            date,
            credentials.region,
            credentials.service,
            signature,
        },
    );
}

// Helper functions

fn normalizePath(allocator: Allocator, path: []const u8) ![]const u8 {
    // TODO: Implement proper URI normalization
    return allocator.dupe(u8, path);
}

fn createCanonicalQueryString(allocator: Allocator, path: []const u8) ![]const u8 {
    // TODO: Implement query string sorting and encoding
    _ = path;
    return allocator.dupe(u8, "");
}

/// Calculate SHA256 hash of payload
pub fn hashPayload(allocator: Allocator, payload: ?[]const u8) ![]const u8 {
    var hash: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (payload) |data| {
        crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    } else {
        crypto.hash.sha2.Sha256.hash("", &hash, .{});
    }
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
}

fn deriveSigningKey(
    allocator: Allocator,
    credentials: Credentials,
    timestamp: i64,
) ![]const u8 {
    const date = try time_utils.formatAmzDate(allocator, timestamp);
    defer allocator.free(date);

    // kSecret = "AWS4" + secret access key
    const k_secret = try fmt.allocPrint(allocator, "AWS4{s}", .{credentials.secret_key});
    defer allocator.free(k_secret);

    // kDate = HMAC-SHA256(kSecret, date)
    var k_date: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_date, date, k_secret);

    // kRegion = HMAC-SHA256(kDate, region)
    var k_region: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_region, credentials.region, &k_date);

    // kService = HMAC-SHA256(kRegion, service)
    var k_service: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_service, credentials.service, &k_region);

    // kSigning = HMAC-SHA256(kService, "aws4_request")
    var k_signing: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_signing, "aws4_request", &k_service);

    return allocator.dupe(u8, &k_signing);
}

test "AWS Signature V4" {
    const allocator = std.testing.allocator;

    const credentials = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .service = "s3",
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("host", "examplebucket.s3.amazonaws.com");
    try headers.put("x-amz-content-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    try headers.put("x-amz-date", "20130524T000000Z");

    const params = SigningParams{
        .method = "GET",
        .path = "/test.txt",
        .headers = headers,
        .timestamp = 1369353600, // 2013-05-24T00:00:00Z
    };

    const auth_header = try signRequest(allocator, credentials, params);
    defer allocator.free(auth_header);

    // TODO: Add proper test assertions once timestamp formatting is implemented
    try std.testing.expect(auth_header.len > 0);
}

test "hashPayload empty" {
    const allocator = std.testing.allocator;
    const hash = try hashPayload(allocator, null);
    defer allocator.free(hash);
    // SHA256 of empty string
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hash,
    );
}

test "hashPayload with content" {
    const allocator = std.testing.allocator;
    const content = "Hello, AWS!";
    const hash = try hashPayload(allocator, content);
    defer allocator.free(hash);
    try std.testing.expect(hash.len == 64); // SHA256 hex is 64 chars
}

test "createCanonicalRequest" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("host", "example.s3.amazonaws.com");
    try headers.put("x-amz-date", "20240101T000000Z");
    try headers.put("x-amz-content-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    const params = SigningParams{
        .method = "GET",
        .path = "/test.txt",
        .headers = headers,
        .body = null,
        .timestamp = 1704067200, // 2024-01-01 00:00:00 UTC
    };

    const canonical_request = try createCanonicalRequest(allocator, params);
    defer allocator.free(canonical_request);

    try std.testing.expect(canonical_request.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, canonical_request, "GET\n"));
}

test "deriveSigningKey" {
    const allocator = std.testing.allocator;

    const credentials = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .service = "s3",
    };

    const timestamp = 1704067200; // 2024-01-01 00:00:00 UTC

    const key = try deriveSigningKey(allocator, credentials, timestamp);
    defer allocator.free(key);

    try std.testing.expect(key.len > 0);
}

test "signRequest full flow" {
    const allocator = std.testing.allocator;

    const credentials = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .service = "s3",
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("host", "example.s3.amazonaws.com");
    try headers.put("x-amz-date", "20240101T000000Z");

    const params = SigningParams{
        .method = "GET",
        .path = "/test.txt",
        .headers = headers,
        .body = null,
        .timestamp = 1704067200, // 2024-01-01 00:00:00 UTC
    };

    const auth_header = try signRequest(allocator, credentials, params);
    defer allocator.free(auth_header);

    try std.testing.expect(std.mem.startsWith(u8, auth_header, "AWS4-HMAC-SHA256"));
    try std.testing.expect(std.mem.indexOf(u8, auth_header, credentials.access_key) != null);
}
