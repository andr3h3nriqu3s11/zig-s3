# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2024-01-19

### Added

- ObjectUploader helper for simplified uploads
  - String content upload
  - JSON serialization and upload
  - File system file upload
- Integration tests with MinIO
- Test assets for integration testing
- Pagination support for listing objects
- Better error handling and validation

### Changed

- Improved memory management in object operations
- Enhanced documentation with more examples
- Restructured project layout
- Updated to Zig 0.13.0

### Fixed

- Memory leaks in error cases
- Proper cleanup in integration tests
- Object key validation

## [0.1.0] - 2024-01-16

### Added

- Initial release
- Basic S3 operations:
  - Bucket creation/deletion
  - Object upload/download
  - List buckets and objects
- AWS Signature V4 authentication
- Support for custom endpoints (MinIO)
- Basic error handling
- Unit tests
- Example application

[0.2.0]: https://github.com/username/zig-s3/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/username/zig-s3/releases/tag/v0.1.0
