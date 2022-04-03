{-# LANGUAGE NamedFieldPuns #-}

module Main where

import Simplex.Messaging.Client.Agent (defaultSMPClientAgentConfig)
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..))
import Simplex.Messaging.Server.CLI (ServerCLIConfig (..), protocolServerCLI)
import System.FilePath (combine)

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex-notifications"

logPath :: FilePath
logPath = "/var/opt/simplex-notifications"

main :: IO ()
main = protocolServerCLI ntfServerCLIConfig runNtfServer

ntfServerCLIConfig :: ServerCLIConfig NtfServerConfig
ntfServerCLIConfig =
  let caCrtFile = combine cfgPath "ca.crt"
      serverKeyFile = combine cfgPath "server.key"
      serverCrtFile = combine cfgPath "server.crt"
   in ServerCLIConfig
        { cfgDir = cfgPath,
          logDir = logPath,
          iniFile = combine cfgPath "ntf-server.ini",
          storeLogFile = combine logPath "ntf-server-store.log",
          caKeyFile = combine cfgPath "ca.key",
          caCrtFile,
          serverKeyFile,
          serverCrtFile,
          fingerprintFile = combine cfgPath "fingerprint",
          defaultServerPort = "443",
          executableName = "ntf-server",
          serverVersion = "SMP notifications server v0.1.0",
          mkServerConfig = \_storeLogFile transports ->
            NtfServerConfig
              { transports,
                subIdBytes = 24,
                clientQSize = 16,
                subQSize = 64,
                pushQSize = 128,
                smpAgentCfg = defaultSMPClientAgentConfig,
                caCertificateFile = caCrtFile,
                privateKeyFile = serverKeyFile,
                certificateFile = serverCrtFile
              }
        }
