# Imagem base enxuta
FROM node:20-slim

# Diretório interno
WORKDIR /app

# Copia apenas package.json primeiro (cache inteligente)
COPY package*.json ./

# Instala dependências
RUN npm install --production

# Copia restante do código
COPY . .

# Porta usada pelo app
EXPOSE 4000

# Comando de inicialização
CMD ["node", "src/index.js"]
