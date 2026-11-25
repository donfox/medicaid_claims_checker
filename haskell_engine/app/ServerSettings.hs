{-# LANGUAGE OverloadedStrings #-}

-- | Warp settings shared by the server and its tests.
module ServerSettings (baseSettings) where

import Network.Wai.Handler.Warp (Settings, defaultSettings, setServerName)

-- | Warp's defaults, without the @Server: Warp/<version>@ header. Warp adds
-- that header to every response, refused requests included, so it would
-- tell anyone who can reach the port which server and version to look up
-- vulnerabilities for. An empty server name leaves the header out.
baseSettings :: Settings
baseSettings = setServerName "" defaultSettings
