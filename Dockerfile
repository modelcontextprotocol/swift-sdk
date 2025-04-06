FROM swift:6.0-noble AS build

WORKDIR /app
COPY . ./
RUN ["swift", "package", "clean"]
CMD ["swift", "test", "--parallel"]
