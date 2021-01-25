#!/bin/sh

echo "Checking sudo…"
sudo echo 👍

git pull
pub get

echo "Building binary…"
dart2native bin/main.dart -o tudo_server

echo "Moving binary to /usr/bin…"
sudo mv tudo_server /usr/bin/
