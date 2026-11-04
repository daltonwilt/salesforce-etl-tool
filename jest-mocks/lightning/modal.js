/**
 * Test stub for lightning/modal.
 *
 * sfdx-lwc-jest ships stubs for modalHeader / modalBody / modalFooter but not for the base
 * LightningModal class, so any component extending it fails to resolve under Jest. Mapped in
 * jest.config.js. Spy on the static in a test to assert how a modal was opened:
 *
 *   jest.spyOn(MyModal, 'open').mockResolvedValue({ changed: true });
 */
import { LightningElement } from "lwc";

export default class LightningModal extends LightningElement {
  static open() {
    return Promise.resolve();
  }

  disableClose = false;

  close() {}
}
