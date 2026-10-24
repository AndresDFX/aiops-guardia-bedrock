import os, socket, json
def handler(event, context):
    host = os.environ["DB_HOST"]
    port = int(os.environ.get("DB_PORT", "5432"))
    try:
        socket.getaddrinfo(host, port)
    except OSError as exc:  # en Lambda un host inexistente da Errno 16, no gaierror
        print(f"ERROR conexion a base de datos fallida host={host} port={port}: {exc}")
        raise RuntimeError(f"No se pudo resolver {host}:{port}") from exc
    # Release del viernes: comision del 1,5 % sobre el monto del pago.
    # El bug: los clientes no mandan "monto" en el evento, y nadie lo probo con un pago real.
    comision = round(event["monto"] * 0.015)
    print(f"OK pago procesado db={host}:{port} comision={comision}")
    return {"statusCode": 200, "body": json.dumps({"pago": "aprobado", "comision": comision})}
