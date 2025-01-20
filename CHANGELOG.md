# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2024-03-XX

### Added

- File upload functionality with automatic binary conversion
- Integration tests for file operations
- Error handling for connection failures
- Documentation for test coverage
- Support for MinIO testing environment

### Changed

- Updated to Zig 0.13.0 syntax
- Improved error handling in makeDir operations
- Reorganized test structure
- Cleaned up build.zig.zon paths

### Fixed

- Connection refused error handling
- Directory creation error handling
- Memory leaks in file operations
- Test cleanup procedures

## [0.1.0] - 2024-03-XX

### Added

- Initial S3 client implementation
- Basic bucket operations (create, delete, list)
- Basic object operations (put, get, delete)
- Basic error handling
- Initial documentation

## [0.3.0] - 2024-04-XX

### Note

- The project is currently under construction and subject to changes.

[0.2.0]: https://github.com/username/zig-s3/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/username/zig-s3/releases/tag/v0.1.0
[0.3.0]: https://github.com/username/zig-s3/compare/v0.2.0...v0.3.0
