/*
 * Copyright (C) 2024 - present Instructure, Inc.
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

import type {RubricCriterion} from '@canvas/rubrics/react/types/rubric'

export type GenerateCriteriaFormProps = {
  criteriaCount: number
  ratingCount: number
  pointsPerCriterion: string
  useRange: boolean
  additionalPromptInfo: string
  gradeLevel: string
}

export type RubricFormProps = {
  id?: string
  title: string
  hasRubricAssociations: boolean
  accountId?: string
  courseId?: string
  criteria: RubricCriterion[]
  pointsPossible: number
  buttonDisplay: string
  ratingOrder: string
  unassessed: boolean
  workflowState: string
  freeFormCriterionComments: boolean
  hideOutcomeResults: boolean
  hidePoints: boolean
  hideScoreTotal: boolean
  useForGrading: boolean
  rubricAssociationId?: string
}

export type RubricFormFieldSetter = <K extends keyof RubricFormProps>(
  key: K,
  value: RubricFormProps[K],
) => void
