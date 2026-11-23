from pathlib import Path
import sys

from impacket import smbserver
from impacket.ntlm import compute_lmhash, compute_nthash


if __name__ == "__main__":
    password = "cinema-test"
    server = smbserver.SimpleSMBServer(listenAddress="127.0.0.1", listenPort=1445)
    server.setSMB2Support(True)
    server.addShare("MOVIES", str(Path(sys.argv[1]).resolve()), readOnly="yes")
    server.addCredential("cinema", 0, compute_lmhash(password), compute_nthash(password))
    server.start()
