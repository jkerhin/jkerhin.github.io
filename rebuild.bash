#!/usr/bin/bash
docker run --rm -v $PWD:/srv/jekyll:Z -v "$PWD/_site":/_site --entrypoint jekyll ghcr.io/actions/jekyll-build-pages:v1.0.9 build -s /srv/jekyll -d /_site --draft
