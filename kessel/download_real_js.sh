#!/bin/bash

mkdir -p real_js
cd real_js

# Download real JavaScript files from popular projects
echo "Downloading real JavaScript files..."

# Lodash (popular utility library)
curl -sL https://raw.githubusercontent.com/lodash/lodash/4.17.21/dist/lodash.js > lodash.js
echo "Lodash: $(wc -c < lodash.js) bytes"

# jQuery (classic library)
curl -sL https://code.jquery.com/jquery-3.6.0.js > jquery.js
echo "jQuery: $(wc -c < jquery.js) bytes"

# Three.js (3D library) - core
curl -sL https://raw.githubusercontent.com/mrdoob/three.js/r128/build/three.js > three.js
echo "Three.js: $(wc -c < three.js) bytes"

# D3.js (data visualization)
curl -sL https://d3js.org/d3.v7.js > d3.js
echo "D3.js: $(wc -c < d3.js) bytes"

# Axios (HTTP client)
curl -sL https://raw.githubusercontent.com/axios/axios/v1.6.0/dist/axios.js > axios.js
echo "Axios: $(wc -c < axios.js) bytes"

# Vue 3 (framework - just the global build)
curl -sL https://unpkg.com/vue@3.3.4/dist/vue.global.js > vue.js 2>/dev/null || echo "Vue: skipped"

# React + ReactDOM (development builds)
curl -sL https://unpkg.com/react@18.2.0/umd/react.development.js > react.js 2>/dev/null || echo "React: skipped"
curl -sL https://unpkg.com/react-dom@18.2.0/umd/react-dom.development.js > react-dom.js 2>/dev/null || echo "ReactDOM: skipped"

# Day.js (lightweight date library)
curl -sL https://unpkg.com/dayjs@1.11.9/dayjs.min.js > dayjs.js 2>/dev/null || echo "Day.js: skipped"

echo ""
echo "Downloaded files:"
ls -lh *.js 2>/dev/null

