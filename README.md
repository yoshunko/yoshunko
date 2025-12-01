# Yoshunko
# ![title](assets/img/title.png)

**Yoshunko** is a server emulator for the game **Zenless Zone Zero**. Its main goal is to provide rich functionality and customization capabilities, while keeping the codebase simple. **Yoshunko** doesn't use any third-party dependencies, except for the zig standard library, of course.

## Getting started
### Requirements
- [Zig 0.16.0-dev.1470](https://ziglang.org/builds/zig-x86_64-linux-0.16.0-dev.1470+32dc46aae.tar.xz)
- [SDK Server](https://git.xeondev.com/reversedrooms/hoyo-sdk/releases)

##### NOTE: this server doesn't include the sdk server as it's not specific per game. You can use `hoyo-sdk` with this server.
##### NOTE 2: this server only works on real operating systems, such as GNU/Linux. If you don't have one, you can use `WSL`.

#### For additional help, you can join our [discord server](https://discord.xeondev.com)
### Setup
#### building from sources
```sh
git clone https://git.xeondev.com/yoshunko/yoshunko.git
cd yoshunko
zig build run-dpsv &
zig build run-gamesv
```

### Configuration
**Yoshunko** doesn't have a config file in particular, however its behavior can be modified with a different approach. The users are intended to manipulate the `state` directory of their servers. For example, list of regions the `dpsv` serves to clients is defined under the `state/gateway` directory. Another example is player data: state of each player is represented as a file system. It's located under `state/player/[UID]` directory. The state files can be edited at any time and the servers will apply these changes immediately. The moment you write to a file under player state directory, server hot-reloads it and synchronizes the state with the client.

### Logging in
Currently supported client version is `CNBetaWin2.5.3`, you can get it from 3rd party sources. Next, you have to apply the necessary [client patch](https://git.xeondev.com/yidhari-zs/Tentacle). It allows you to connect to the local server and replaces encryption keys with custom ones.

## Community
- [Our Discord Server](https://discord.xeondev.com)
- [Our Telegram Channel](https://t.me/reversedrooms)

## Donations
Continuing to produce open source software requires contribution of time, code and -especially for the distribution- money. If you are able to make a contribution, it will go towards ensuring that we are able to continue to write, support and host the high quality software that makes all of our lives easier. Feel free to make a contribution [via Boosty](https://boosty.to/xeondev/donate)!

