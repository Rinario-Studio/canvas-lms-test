/*
 * Copyright (C) 2025 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import {useScope as createI18nScope} from '@canvas/i18n'
import {PropsWithChildren} from 'react'
import {IconButton} from '@instructure/ui-buttons'
import {IconUploadLine} from '@instructure/ui-icons'

const I18n = createI18nScope('page_editor')

export const ImageActionsWrapper = (
  props: PropsWithChildren<{
    showActions: boolean
    onUploadClick: () => void
  }>,
) => {
  return (
    <div className="image-actions-container">
      {props.children}
      {props.showActions && (
        <div className="image-actions">
          <IconButton
            renderIcon={<IconUploadLine />}
            onClick={props.onUploadClick}
            screenReaderLabel={I18n.t('Change image')}
            size="small"
          />
        </div>
      )}
    </div>
  )
}
