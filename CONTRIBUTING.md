# Contributing to Jenkins HA Migration

First off, thank you for considering contributing to this project! 

## Code of Conduct

This project and everyone participating in it is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues. When creating a bug report, please include:

- A clear and descriptive title
- Steps to reproduce the issue
- Expected behavior
- Actual behavior
- Environment details (OS, versions, etc.)
- Logs and error messages

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, please include:

- A clear and descriptive title
- A detailed description of the proposed enhancement
- Use cases and examples
- Potential implementation approach

### Pull Requests

1. Fork the repo and create your branch from `main`
2. If you've added code, add tests
3. Ensure the test suite passes
4. Make sure your code follows the style guidelines
5. Issue the pull request

## Development Setup

```bash
# Clone your fork
git clone https://github.com/your-username/jenkins-ha-migration.git
cd jenkins-ha-migration

# Add upstream remote
git remote add upstream https://github.com/GITHUB_USERNAME/jenkins-ha-migration.git

# Create a feature branch
git checkout -b feature/your-feature-name

# Install development dependencies
make dev-setup
```

## Style Guidelines

### Git Commit Messages

- Use the present tense ("Add feature" not "Added feature")
- Use the imperative mood ("Move cursor to..." not "Moves cursor to...")
- Limit the first line to 72 characters or less
- Reference issues and pull requests liberally after the first line

### Code Style

- Shell scripts: Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- YAML: 2 spaces indentation
- Documentation: Markdown with proper formatting

### Testing

- Write tests for any new functionality
- Ensure all tests pass before submitting PR
- Include integration tests for complex features

## Review Process

1. A maintainer will review your PR
2. Address any requested changes
3. Once approved, a maintainer will merge your PR

## Community

- Join our [Slack channel](https://example.slack.com)
- Attend our weekly community meetings (Thursdays 3PM UTC)
- Subscribe to our [mailing list](https://groups.google.com/forum/#!forum/jenkins-ha-migration)
