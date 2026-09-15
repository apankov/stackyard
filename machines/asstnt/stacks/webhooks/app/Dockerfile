FROM node:24-alpine

WORKDIR /app

# Копируем package.json
COPY package.json ./

# Копируем код
COPY server.js ./

# Настройка прав (Запуск от node, а не root)
RUN mkdir -p /storage && chown -R node:node /app /storage
USER node

EXPOSE 3000

ENV STORAGE_PATH=/storage
ENV PORT=3000
ENV BUCKET_NAME=fathom

# Запуск с нативным флагом Node.js 24 для чтения .env
# CMD ["node", "--env-file=/app/.env", "server.js"]
CMD ["node", "server.js"]
