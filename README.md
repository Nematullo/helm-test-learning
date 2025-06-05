# helm-test-learning
new charts
30099 loki



curl -G -s "http://192.168.49.2:31000/loki/api/v1/query"   --data-urlencode 'query={job="current-time"}'   --data-urlencode 'limit=5'

