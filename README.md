# Stacklok Enterprise reference architectures

This repository holds runnable reference architectures for installing Stacklok
Enterprise. Each architecture is one supported way to deploy it into one kind of
environment.

Each architecture lives in its own directory and has the same three scripts:

- `up.sh` brings it up and is safe to re-run.
- `verify.sh` smoke-tests it through its public endpoints and exits non-zero on failure.
- `down.sh` removes it.

## How this repository is maintained

The content here is generated. Stacklok publishes a snapshot of each
architecture after it passes verification against a Stacklok Enterprise
release, and tags the snapshot with that release's version. Check out the tag
that matches the version you run.

Changes arrive as pull requests, opened by the publishing automation or by
Stacklok staff. Issues are turned off. For help with an architecture, contact
Stacklok support.

No architectures have been published yet.

## License

[Apache-2.0](LICENSE)
