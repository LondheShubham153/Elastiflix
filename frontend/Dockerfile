FROM node:23-alpine AS build

WORKDIR /app

COPY package*.json ./

# Install dependencies
RUN npm install --legacy-peer-deps


COPY . .


ENV DISABLE_ESLINT_PLUGIN=true
ENV CI=false

RUN npm run build

FROM nginx:alpine AS production

COPY --from=build /app/build /usr/share/nginx/html


# Expose port 3000
EXPOSE 3000

# Start the application
CMD ["nginx", "-g", "daemon off;"]