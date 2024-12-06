import asyncio
import aiohttp
import msgpack
import traceback


class ProtocolError(Exception):

    def __init__(self, msg):
        self.msg = msg


class Protocol:

    def __init__(self, session):
        self.session = session
        self.changes = []

    async def search(self, query):
        url = self.index_url + f"/{self.index_name}/_search"
        data = msgpack.dumps({"q": query})
        headers = {
            "Content-Type": "application/vnd.msgpack",
            "Accept": "application/vnd.msgpack",
        }
        async with self.session.post(url, data=data, headers=headers) as resp:
            resp.raise_for_status()
            body = msgpack.loads(await resp.content.read())
            return [(r["i"], r["s"]) for r in body["r"]]

    async def update(self, changes):
        url = self.index_url + f"/{self.index_name}/_update"
        data = msgpack.dumps({"c": changes})
        headers = {
            "Content-Type": "application/vnd.msgpack",
            "Accept": "application/vnd.msgpack",
        }
        async with self.session.post(url, data=data, headers=headers) as resp:
            body = await resp.content.read()
            resp.raise_for_status()

    async def handle_request(self, request):
        if not request:
            raise ProtocolError("invalid command")

        if request[0] == "search":
            query = list(map(int, request[1].split(",")))
            results = await self.search(query)
            return " ".join(f"{docid}:{hits}" for (docid, hits) in results)

        if request[0] == "begin":
            self.changes = []
            return ""

        if request[0] == "rollback":
            self.changes = []
            return ""

        if request[0] == "commit":
            await self.update(self.changes)
            self.changes = []
            return ""

        if request[0] == "insert":
            self.changes.append(
                {
                    "i": {
                        "i": int(request[1]),
                        "h": [int(v) for v in request[2].split(",")],
                    }
                }
            )
            return ""

        raise ProtocolError("invalid command")


class Server:

    def __init__(self):
        self.host = "127.0.0.1"
        self.port = 6080
        self.index_name = "main"
        self.index_url = "http://localhost:8080"

    async def run(self):
        async with aiohttp.ClientSession() as session:
            self.session = session
            server = await asyncio.start_server(
                self.handle_connection, self.host, self.port
            )
            async with server:
                await server.serve_forever()

    async def handle_connection(self, reader, writer):
        try:
            proto = Protocol(self.session)
            proto.index_name = self.index_name
            proto.index_url = self.index_url

            while True:
                try:
                    line = await reader.readuntil(b"\n")
                except asyncio.exceptions.IncompleteReadError:
                    return

                try:
                    response = await proto.handle_request(line.decode("ascii").split())
                    writer.write(b"OK " + response.encode("ascii") + b"\n")
                except ProtocolError as ex:
                    writer.write(b"ERR " + ex.msg.encode("ascii") + b"\n")
                except Exception:
                    traceback.print_exc()
                    writer.write(b"ERR internal error\n")

                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()


async def main():
    srv = Server()
    await srv.run()


if __name__ == "__main__":
    asyncio.run(main())
