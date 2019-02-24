#!/bin/sh

set -x

jazzy --clean --author Lookback --author_url https://lookback.io --github_url https://github.com/lookback/froop-swift --module froop --output docs/
