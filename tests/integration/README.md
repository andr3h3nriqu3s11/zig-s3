# Integration Tests for S3 Client

These tests verify the functionality of the S3 client against a real
S3-compatible server (like MinIO). The tests require a running MinIO instance
with default credentials.

## Prerequisites

1. Running MinIO server:

```bash
docker run -p 9000:9000 minio/minio server /data
```

2. Default MinIO credentials:

- Access Key: minioadmin
- Secret Key: minioadmin
- Endpoint: http://localhost:9000

3. System requirements:

- Network access to localhost:9000
- Sufficient disk space for temporary files
- Docker (for running MinIO)

## Test Coverage

### 1. Full Client Lifecycle Test

**Purpose**: Verifies basic end-to-end functionality of the S3 client

**Coverage**:

- Client initialization with config
- Bucket creation and verification
- Multiple content type uploads:
  - String content ("hello.txt")
  - JSON data (config.json)
  - File upload (test.dat)
- Object listing and verification
- Content retrieval and validation
- Object deletion and cleanup

### 2. Error Handling Test

**Purpose**: Validates proper error handling in various scenarios

**Coverage**:

- Non-existent bucket operations
- Non-existent object retrieval
- Invalid bucket name validation
- Invalid object key validation
- Connection error handling

### 3. Pagination and Prefixes Test

**Purpose**: Tests object listing functionality

**Coverage**:

- Multiple object creation (15 objects across 3 folders)
- Pagination with different page sizes
- Prefix-based filtering
- Complete object listing
- Proper cleanup of test objects

### 4. File Upload and Download Test

**Purpose**: Comprehensive testing of file operations

**Coverage**:

- Temporary test directory management
- Local file creation and writing
- File upload to S3
- Content download and verification
- Object metadata verification
- Object listing with prefixes
- Cleanup and deletion verification

## Running the Tests

1. Start MinIO:

```bash
docker run -p 9000:9000 minio/minio server /data
```

2. Run integration tests:

```bash
zig build integration-test
```

3. Run all tests (unit + integration):

```bash
zig build test
```

## Test Design Notes

1. **Resource Cleanup**:
   - All tests use `defer` statements to ensure cleanup
   - Temporary files, buckets, and objects are removed after tests
   - Failed tests should not leave artifacts

2. **Test Independence**:
   - Each test creates its own bucket with a unique name
   - Tests can be run in parallel
   - No shared state between tests

3. **Error Handling**:
   - Tests verify both success and error cases
   - Connection errors are handled gracefully
   - Invalid input is properly validated

4. **Memory Management**:
   - All allocations are properly freed
   - No memory leaks in test code
   - Proper use of defer for cleanup

## Troubleshooting

1. **Connection Refused**:
   - Ensure MinIO is running
   - Check if port 9000 is accessible
   - Verify no firewall blocking access

2. **Authentication Failures**:
   - Verify MinIO credentials match test configuration
   - Check MinIO logs for auth errors

3. **Resource Cleanup Issues**:
   - Manually verify no leftover test buckets
   - Check temporary directory for leftover files
   - Use MinIO console to inspect state

## Contributing New Tests

When adding new integration tests:

1. Follow the existing pattern of test organization
2. Ensure proper resource cleanup
3. Add test documentation to this README
4. Verify tests work with clean MinIO instance
5. Include both success and error cases
