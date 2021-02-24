import 'dart:ui';

const systemUser = '00000000-0000-0000-0000-000000000000';

const scp =
    'PROFILE:READ PROFILE:WRITE PHONE:READ PHONE:WRITE CONTACTS:READ CONTACTS:WRITE MESSAGES:READ MESSAGES:WRITE ASSETS:READ SNAPSHOTS:READ CIRCLES:READ CIRCLES:WRITE';

const acknowledgeMessageReceipts = 'ACKNOWLEDGE_MESSAGE_RECEIPTS';
const sendingMessage = 'SENDING_MESSAGE';
const resendMessages = 'RESEND_MESSAGES';
const createMessage = 'CREATE_MESSAGE';
const resendKey = 'RESEND_KEY';

const mixinScheme = 'mixin';
enum MixinSchemeHost {
  codes,
  pay,
  users,
  transfer,
  device,
  send,
  address,
  withdrawal,
  apps,
  snapshots,
}

const mixinProtocolUrls = {
  MixinSchemeHost.codes: 'https://mixin.one/codes',
  MixinSchemeHost.transfer: 'https://mixin.one/transfer',
  MixinSchemeHost.address: 'https://mixin.one/address',
  MixinSchemeHost.withdrawal: 'https://mixin.one/withdrawal',
  MixinSchemeHost.apps: 'https://mixin.one/apps',
  MixinSchemeHost.snapshots: 'https://mixin.one/snapshots'
};
