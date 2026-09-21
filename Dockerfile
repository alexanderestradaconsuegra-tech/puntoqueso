FROM nginx:alpine
COPY puntoqueso-os.html /usr/share/nginx/html/index.html
COPY manifest.json /usr/share/nginx/html/manifest.json
COPY sw.js /usr/share/nginx/html/sw.js
COPY icon-192.png /usr/share/nginx/html/icon-192.png
COPY icon-512.png /usr/share/nginx/html/icon-512.png
COPY icon-180.png /usr/share/nginx/html/icon-180.png
COPY favicon.png /usr/share/nginx/html/favicon.png
COPY favicon.ico /usr/share/nginx/html/favicon.ico
COPY logo.png /usr/share/nginx/html/logo.png
EXPOSE 80
