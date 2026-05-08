#!/usr/bin/env node
// Exchanges a Google Service Account key for a pub.dev identity token.
// Reads GOOGLE_SERVICE_ACCOUNT_KEY from env, writes the bearer token to stdout.
import { GoogleAuth } from 'google-auth-library';

const keyJson = process.env.GOOGLE_SERVICE_ACCOUNT_KEY;
if (!keyJson) {
  process.stderr.write('Error: GOOGLE_SERVICE_ACCOUNT_KEY is not set\n');
  process.exit(1);
}

const credentials = JSON.parse(keyJson);
const auth = new GoogleAuth({ credentials });
const client = await auth.getIdTokenClient('https://pub.dev');
const headers = await client.getRequestHeaders('https://pub.dev');
const token = headers['Authorization'].replace('Bearer ', '');
process.stdout.write(token);
