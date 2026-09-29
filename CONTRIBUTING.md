# Contributing to resilience

## Support

One maintainer looks after this package, best effort. There is no promised
response time and no release schedule.

## Bug reports

A good bug report contains:

* The resilience version your app resolves, from `pubspec.lock`.
* The full output of `dart --version`.
* The operating system it ran on and how the code ran (Dart VM, compiled executable, or a Flutter app).
* A minimal reproduction, the smallest code that shows the problem.

## Setup

Install the Dart SDK. This package needs:

* Dart SDK `^3.8.0`

## Checks

Run these in the repository root. CI runs the same four commands:

```
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

## Pull requests

* One change per pull request.
* Add an entry to `CHANGELOG.md`.
* Link the issue, for example `Fixes #12`.
