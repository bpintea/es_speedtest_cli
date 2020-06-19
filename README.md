# Elasticsearch backed Speedtest probe

This is a simple Bash script "app" that will run
[Speedtest](https://www.speedtest.net/apps/cli) and upload the measurements
into an [Elasticsearch](https://www.elastic.co/elasticsearch/) instance.

The script is an all-in-one package that will take care of creating the
Elasticsearch resources, run the speedtest app and upload its results, as well
as install/uninstall itself.

## Requirements

There are a few dependencies, besides `speedtest` that need to be available on
the system before running this script:
 * curl
 * cron
 * jq
 * bc

These are checked on installation only and expected to be available otherwise.

## Installation

0. Edit the config file, `esst.conf` and change the defines between the
 `<change me>` tags in both "Elasticsearch" and "Local" sections.

1. Create the Elasticsearch resources

   This step needs to be done only once, even if probing with Speedtest on
   multiple hosts. Run:
   ```
   ./esst.sh init
   ```
   This will create the index template, the pipeline that alters the JSON that
   Speedtest produces, as well as an index lifecycle managment policy to
   manage the data rotation.

   The opposite of `init` is `drop`, which will delete all resources created
   initially.

2. Install the "app"
   ```
   ./esst.sh install
   ```
   This will install the needed files under `/opt/esst` directory (by default),
   as well as register a cron entry in the crontab of **executing user**. This
   won't make it available in the `PATH`. To later uninstall it, list the cron
   entries (`crontab -l`) to find its location and run `uninstall`; below is an
   example that works with the default configuration:
   ```
   /opt/esst/esst uninstall
   ```

3. Make a test run
   To produce one measurement, invoke it with the `probe` argument:
   ```
   /opt/esst/esst probe
   ```

## Kibana Dashboard

There is one simple dashboard configuration file that can be uploaded into
Kibana, `dashboard.ndjson`. This will install a graph of upload and download
measurements, as well as a gauge with the max RTT to the speedtest server, over
all collected data.
