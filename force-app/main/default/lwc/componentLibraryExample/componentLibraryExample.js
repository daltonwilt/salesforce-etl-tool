import { LightningElement, api } from "lwc";

/**
 * Renders the live example for the component library's Example tab.
 *
 *   <c-component-library-example name="exampleMultiSelect"></c-component-library-example>
 *
 * A static branch per example rather than a dynamic component (lwc:is): dynamic components need
 * the lightning__dynamicComponent capability, and a branch here is the only change adding an
 * example takes.
 */
export default class ComponentLibraryExample extends LightningElement {
  @api name;

  get show() {
    return { [this.name]: true };
  }
}
