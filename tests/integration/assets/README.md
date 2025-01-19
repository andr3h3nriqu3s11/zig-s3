# Test Assets

This directory contains static files used for integration testing of the S3
client.

## Files

1. `sample.txt`
   - Simple text file with multiple lines
   - Used for basic file upload/download tests
   - Tests line ending preservation
   - Tests UTF-8 encoding

2. `config.json`
   - Sample JSON configuration file
   - Tests JSON parsing and serialization
   - Contains nested objects and arrays
   - Tests metadata preservation

## Usage

These files are used in the integration tests to verify:

- File upload functionality
- Content integrity
- Metadata preservation
- Content type handling
- Character encoding
- File size handling

## Adding New Assets

When adding new test assets:

1. Keep files small (< 1MB)
2. Include documentation in this README
3. Use realistic but safe test data
4. Consider adding different file types for broader testing
