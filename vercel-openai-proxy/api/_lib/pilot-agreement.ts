import { createHash } from 'node:crypto';

// Immutable publication: change the version whenever the displayed text changes.
// Wording approved on 2026-10-19; deployment must explicitly enable this version.
export const pilotAgreement = {
  version: '2026-10-19.1',
  title: 'Before you begin',
  introduction: 'By using this app, you acknowledge and agree as follows:',
  paragraphs: [
    '1. **Pilot / experimental.** This is an MVP pilot of CollectiveCare Digital Health Ltd. It may contain errors, lose data, or stop working. It is provided “as is,” without warranties of any kind.',
    '2. **What the app does/Not medical care.** This app helps you collect, organize, and summarize personal health information you choose to enter or import (such as notes, audio, images, PDFs, and lab results), primarily on your device, with AI-assisted summaries of selected content. The app does not provide medical advice, diagnosis, or treatment and is not a substitute for a physician or other qualified provider. Do not rely on it for health decisions. Seek professional care for medical concerns, including emergencies. (No medical-device classification is asserted for this pilot; a formal assessment may be required before any broader commercial release if functionality changes.)',
    '3. **Your data.** You enter and control the information, including personal health information such as lab results and medication notes. You are responsible for its accuracy and for what you choose to add, store, or share. Data is stored primarily on your device. Deleting the app or data may permanently remove it; there is no guarantee of backup or recovery. Content you add will be sent for AI-assisted summarization. Any such cloud processing is temporary, results are returned for your review, and the content is not used to train AI models. Content and results may be temporarily retained to complete processing and support recovery from interruptions.',
    '4. **AI summaries.** Information that is processed will be summarized by AI. Where cloud-based summarization occurs, selected content is sent temporarily to a third-party service (such as OpenAI) for processing only; it is not stored for training and results are returned for your review. Summaries can be incomplete, inaccurate, or misleading. They are not clinical interpretations. You should review the results against the source records yourself.',
    '5. **Sharing.** Sharing can only be initiated by you. You are responsible for who you choose to share your data with and any subsequent disclosure or sharing by them. During the pilot, you may also choose to share screenshots, PDFs, or screen-share health information with CollectiveCare Digital Health Ltd. for limited user-research or usability purposes; such sharing is voluntary and subject to separate confirmation of consent and handling practices.',
    '6. **Assumption of risk and release.** To the maximum extent permitted by law, you assume all risk of use and release CollectiveCare Digital Health Ltd. and its personnel from claims arising from the app, including data loss, inaccurate summaries, reliance on outputs, or sharing, except where liability cannot legally be limited.',
    '7. Age. You confirm you are 18 or older, or using the app with authority to consent for the account holder.'
  ],
  action: 'I agree and continue'
};
export const agreementText = [pilotAgreement.introduction, ...pilotAgreement.paragraphs, pilotAgreement.action].join('\n\n');
export const agreementHash = createHash('sha256').update(agreementText, 'utf8').digest('hex');
export function validateAcceptance(body: unknown): { appVersion: string; appBuild: string } {
  const b = body as Record<string, unknown> | null;
  if (!b || b.version !== pilotAgreement.version || b.sha256 !== agreementHash || b.action !== pilotAgreement.action)
    throw Object.assign(new Error('agreement_changed'), { status: 409 });
  for (const key of ['appVersion', 'appBuild']) {
    if (typeof b[key] !== 'string' || !/^[0-9A-Za-z._-]{1,40}$/.test(b[key] as string))
      throw Object.assign(new Error('invalid_acceptance'), { status: 400 });
  }
  return { appVersion: b.appVersion as string, appBuild: b.appBuild as string };
}
