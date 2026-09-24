FROM node:23-alpine AS build

WORKDIR /app

COPY package*.json ./

# Install dependencies
RUN npm install --legacy-peer-deps


COPY . .

RUN npm run build

FROM nginx:alpine AS production

COPY --from=build /app/build /usr/share/nginx/html


# Expose port 3000
EXPOSE 3000

# Start the application
CMD ["nginx", "-g", "daemon off;"]