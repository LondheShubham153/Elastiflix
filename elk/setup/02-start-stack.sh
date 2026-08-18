#!/usr/bin/env bash
# Bring up Elasticsearch + Kibana + Logstash + Filebeat + Metricbeat,
# apply the movie index template, then start Elastiflix itself.
set -euo pipefail
cd "$(dirname "$0")/.."

ES="http://localhost:9200"

echo "==> Starting Elasticsearch and Kibana"
docker compose -f docker-compose.elk.yml up -d elasticsearch kibana

echo "==> Waiting for Elasticsearch"
until curl -fs "$ES/_cluster/health" >/dev/null 2>&1; do printf '.'; sleep 2; done
echo " up"

echo "==> Applying index templates"
# Templates FIRST, before any data arrives. If you let Elasticsearch guess via
# dynamic mapping instead, release_date becomes a string and search_query
# becomes `text` -- which means you cannot aggregate on it, and the "top search
# terms" panel is impossible. Mapping is not something you fix later.
curl -fs -X PUT "$ES/_index_template/elastiflix-movies" \
  -H 'Content-Type: application/json' \
  -d @logstash/templates/movies-template.json > /dev/null
curl -fs -X PUT "$ES/_index_template/elastiflix-logs" \
  -H 'Content-Type: application/json' \
  -d @logstash/templates/logs-template.json > /dev/null
echo "    movies + logs templates applied"

echo "==> Starting Logstash, Filebeat and Metricbeat"
docker compose -f docker-compose.elk.yml up -d

echo "==> Starting Elastiflix (frontend + backend)"
docker compose -f ../docker-compose.yml up -d

echo "==> Creating Kibana data views"
./setup/04-kibana-dataviews.sh

cat <<'EOF'

  Elasticsearch   http://localhost:9200
  Kibana          http://localhost:5601
  Elastiflix      http://localhost:3000
  Logstash API    http://localhost:9600

  Watch the movie catalog load:
      curl -s localhost:9200/elastiflix-movies/_count      # -> 6959

  Generate search traffic so Kibana has something to chart:
      ./setup/03-generate-traffic.sh

EOF
