import http from "node:http";

http.createServer(async (_, response) => {
  const result = await DenoRider.apply("Kernel", "+", [1, 2]);
  response.writeHead(200);
  response.end(`Result: ${result}`);
}).listen(3000);
