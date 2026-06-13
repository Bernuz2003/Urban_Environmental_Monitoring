# Data generation design

La generazione è deliberatamente separata dal repository principale. Il modello produce correlazioni plausibili tra traffico, inquinanti, meteo, verde urbano e rumore. I dati storici sono prodotti una sola volta e successivamente trattati come un dataset esterno immutabile.

- raw: ultimi 30 giorni, 15 minuti, livello sensore;
- hourly: ultimo anno, livello zona;
- daily: ultimi 3 anni, soli giorni locali completi di New York;
- live feed: quattro batch raw precomputati, senza alert preconfezionati.


## Precisione temporale

I file storici InfluxDB usano Unix epoch in microsecondi (`us`). Il runtime deve importarli con `influx write --precision us`. La precisione è dichiarata anche nel manifest del dataset.
