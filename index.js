const https = require('https');
const AWS = require('aws-sdk');
const s3 = new AWS.S3();
// List of OIDC providers
let oidc_providers = JSON.parse(process.env.oidc_providers);
// Destination S3 bucket name
let dest_bucket_name = process.env.dest_bucket_name;
// Destination S3 bucket path for output files
let dest_bucket_path = process.env.dest_bucket_path;

// Fetches openid configuration at ./.well-known/openid-configuration (Adapted from https://nodejs.org/dist/latest-v16.x/docs/api/http.html#httpgetoptions-callback)
let fetch_openid_configuration = function (provider) {
  return new Promise(function (resolve, reject) {
    https.get("https://" + provider + "/.well-known/openid-configuration", (res) => {
      const { statusCode } = res;
      const contentType = res.headers['content-type'];

      let error;
      // Any 2xx status code signals a successful response but
      // here we're only checking for 200.
      if (statusCode !== 200) {
        error = new Error('Request Failed.\n' +
          `Status Code: ${statusCode}`);
      } else if (!/^application\/json/.test(contentType)) {
        error = new Error('Invalid content-type.\n' +
          `Expected application/json but received ${contentType}`);
      }
      if (error) {
        console.error(error.message);
        // Consume response data to free up memory
        res.resume();
        reject(error);
      }

      res.setEncoding('utf8');
      let rawData = '';
      res.on('data', (chunk) => { rawData += chunk; });
      res.on('end', () => {
        try {
          // Parse JSON to check syntax and eventually do some preprocessing or formating later on
          const parsedData = JSON.parse(rawData);
          resolve({ provider: provider, configuration: parsedData });
        } catch (e) {
          console.error(e.message);
          reject(Error(e));
        }
      });
    }).on('error', (e) => {
      reject(Error(e))
    })
  })
};

exports.handler = async function (event) {
  const promise = new Promise(function (resolve, reject) {
    let promises = oidc_providers.map(provider => fetch_openid_configuration(provider));
    Promise.allSettled(promises).then((results) => {
      let s3_promises = [];
      results.forEach((result) => {
        if (result.status == "fulfilled") {
          try {
            const destparams = {
              Bucket: dest_bucket_name,
              Key: dest_bucket_path + "" + result.value.provider,
              Body: JSON.stringify(result.value.configuration),
              ContentType: "application/json"
            };
            s3_promises.push(s3.putObject(destparams).promise());
          } catch (error) {
            console.log(error);
          }
        }
      });
      Promise.all(s3_promises).then((s3_results) => resolve(s3_results));
    });
  });
  return promise;
};
