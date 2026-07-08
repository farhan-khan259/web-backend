const express = require('express');
const cors = require('cors');
const { fetchProtocolData, parseError, normalizeForJson } = require('./utils');

const app = express();
const port = process.env.PORT || 4000;

app.use(cors());
app.use(express.json());

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/api/protocol', async (req, res) => {
  try {
    const data = await fetchProtocolData();
    res.json({ success: true, data: normalizeForJson(data) });
  } catch (err) {
    res.status(500).json({ success: false, error: parseError(err) });
  }
});

// Root route: provide quick status and available endpoints
app.get('/', (req, res) => {
  res.json({ success: true, message: 'EWB backend API', endpoints: ['/health', '/api/protocol'] });
});

app.listen(port, () => {
  console.log(`API Server is running on port ${port}`);
});
