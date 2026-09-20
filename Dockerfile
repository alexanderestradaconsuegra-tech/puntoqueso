FROM nginx:alpine
COPY puntoqueso-os.html /usr/share/nginx/html/index.html
EXPOSE 80
