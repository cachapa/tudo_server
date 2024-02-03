<img src="tudo.svg" width="240">

an experiment in simple connected to-do lists.

This project is the server counterpart to the [tudo app](https://github.com/cachapa/tudo).

## Usage

Note that `tudo_server` uses PostgresSQL database to store its data, so make sure you have access to a running instance.

The simplest way to run the program is to run main.dart:

``` shell
$ dart pub get
$ dart bin/main.dart
Serving at http://localhost:8080
```

However, you might prefer to precompile the program into native code, making it much more efficient:

``` shell
$ dart pub get
$ dart compile exe bin/main.dart -o tudo_server
$ ./tudo_server
Serving at http://localhost:8080
```

Run `tudo_server --help` for server configuration options.

## Hosting

While this project can be hosted from any internet-accessible device, keep in mind:

* It isn't suited for serverless hosting (e.g. Amazon Lambda, Google Cloud Run) since the server uses websockets for long-running sessions
* HTTPS is required as modern Android and iOS versions disallow apps from establishing plaintext connections

## How to contribute

Please file feature requests and bugs at the [issue tracker](https://github.com/cachapa/tudo_server/issues).

